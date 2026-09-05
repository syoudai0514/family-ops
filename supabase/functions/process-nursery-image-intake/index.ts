// Q89-Q106 worker. Provider interaction is LINE content READ only; no LINE
// send and no Google/provider mutation. Canonical changes remain behind the
// authenticated human-confirm endpoint.
import { createServiceRoleClient, requireWorkerToken } from '../_shared/auth.ts';
import { jsonResponse, withServiceHandler } from '../_shared/handler.ts';
import { assertPrivacySafeStructuredValue, isSafeExternalUrl, mayGroupNurseryPages, requiredClarificationFields, type NurseryAnalysis } from '../_shared/nurseryImage.ts';

type Claimed = {
  id: string; provider_event_id: string; line_message_id: string; household_id: string;
  actor_id: string; line_user_id: string; revision: number; received_at: string;
};
type ContextRow = { id: string; school_display_name: string; class_display_name: string | null; recognition_aliases: string[] | null };
type ReviewItem = { candidate_key: string; origin: 'source_explicit'|'ai_inference'; item_kind: string; classification?: string | null; source_page: number; source_locator?: string; confidence_band: 'high'|'medium'|'low'; proposed_value: Record<string, unknown> };
type ModelResult = NurseryAnalysis & { review_items: ReviewItem[] };
type PreviousImage = { found: boolean; intake_id?: string; received_at?: string; page_index?: number | null };

const WORKER_ID = `process-nursery-image-intake:${crypto.randomUUID()}`;

async function fetchLineImage(messageId: string): Promise<{ bytes: Uint8Array; contentType: string }> {
  const token = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN') ?? '';
  if (!token) throw new Error('LINE_CHANNEL_ACCESS_TOKEN_MISSING');
  const response = await fetch(`https://api-data.line.me/v2/bot/message/${encodeURIComponent(messageId)}/content`, { headers: { Authorization: `Bearer ${token}` } });
  if (!response.ok) throw new Error(`LINE_CONTENT_HTTP_${response.status}`);
  const length = Number(response.headers.get('content-length') ?? '0');
  if (length > 10 * 1024 * 1024) throw new Error('NURSERY_IMAGE_TOO_LARGE');
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength > 10 * 1024 * 1024) throw new Error('NURSERY_IMAGE_TOO_LARGE');
  return { bytes, contentType: response.headers.get('content-type') ?? 'image/jpeg' };
}

async function analyzeImage(bytes: Uint8Array, contentType: string, contexts: ContextRow[], hasRecentPage: boolean): Promise<ModelResult> {
  const apiKey = Deno.env.get('GEMINI_API_KEY') ?? '';
  const model = Deno.env.get('GEMINI_MODEL_VISION') ?? Deno.env.get('GEMINI_MODEL_REWRITE') ?? '';
  if (!apiKey || !model) throw new Error('GEMINI_NOT_CONFIGURED');
  let binary = ''; for (let i=0;i<bytes.length;i+=0x8000) binary += String.fromCharCode(...bytes.subarray(i,Math.min(i+0x8000,bytes.length)));
  const prompt = [
    'Family Ops nursery notice triage. Return JSON only.',
    'First decide triage: ordinary_photo, nursery_notice, or needs_clarification. Ordinary family photos must not be extracted.',
    'Never return names/contact/address/roster/other-child data. Include only facts/actions for the selected household child/class.',
    'Contexts: '+JSON.stringify(contexts),
    `A recent image page from the same LINE sender exists within 10 minutes: ${hasRecentPage ? 'yes' : 'no'}. Set same_document_as_previous=true only when this image itself gives evidence it continues that notice (page numbering, repeated heading/layout/context, or explicit continuation). Time proximity alone is not enough.`,
    'Schema: {triage,same_document_as_previous,child_school_context_id,context_confidence,ambiguous_fields,source_facts,ai_candidates,review_items}.',
    'review_items entries: candidate_key, origin(source_explicit|ai_inference), item_kind(preparation|task|timetable|shared_info|submission|url|recurrence|exception), classification(recommended|other only for timetable), source_page, source_locator, confidence_band, proposed_value.',
    'For preparation use proposed_value {trigger_spec:{event?|event_type?|weekday?|month?|date?|condition?|title_contains?|classification?},preparation_template:{items:[string|{title,quantity?,note?,category?}],tasks?:[],checklist?:[],notes?:string},effective_from,effective_to?}. Keep the structure small; never include transcripts or people.',
    'For timetable use proposed_value {title,date,location?,details?}. For shared_info use {text,date?}. For URL use proposed_value {title,due_date,url}; only http/https. For tasks and submissions use {title,due_date}. Never choose calendar inclusion for a submission; that is a human review choice. For recurrence always include effective_from/effective_to <= 366 days and rule_spec.',
    'Keep Other timetable items. Ask ambiguity only for nursery/child/class/date/document_group.',
  ].join('\n');
  const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`, {
    method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({ contents:[{parts:[{text:prompt},{inlineData:{mimeType:contentType,data:btoa(binary)}}]}], generationConfig:{temperature:0,responseMimeType:'application/json'} }),
  });
  if (!response.ok) throw new Error(`GEMINI_HTTP_${response.status}`);
  const body = await response.json(); const text = body?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (typeof text !== 'string') throw new Error('GEMINI_EMPTY_RESPONSE');
  const parsed = JSON.parse(text) as ModelResult;
  if (!['ordinary_photo','nursery_notice','needs_clarification'].includes(parsed.triage)) throw new Error('NURSERY_TRIAGE_INVALID');
  if (!Array.isArray(parsed.review_items) || parsed.review_items.length > 64) throw new Error('NURSERY_REVIEW_ITEMS_INVALID');
  for (const item of parsed.review_items) {
    assertPrivacySafeStructuredValue(item.proposed_value);
    if (item.item_kind === 'url' && typeof item.proposed_value.url === 'string' && !isSafeExternalUrl(item.proposed_value.url)) throw new Error('NURSERY_UNSAFE_URL');
  }
  parsed.ambiguous_fields = requiredClarificationFields(parsed);
  return parsed;
}

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req);
  const client = createServiceRoleClient();
  const { data, error } = await client.rpc('server_tx_claim_nursery_line_images', { p_limit: 5, p_worker: WORKER_ID });
  if (error) throw error;
  const claimed = (data ?? []) as Claimed[];
  let processed=0;
  for (const item of claimed) {
    let currentRevision = item.revision;
    try {
      if (Deno.env.get('TEST_MODE') === '1') throw new Error('TEST_MODE_PROVIDER_READ_DISABLED');
      const { data: previousData, error: previousError } = await client.rpc('server_read_previous_nursery_image',{p_current_id:item.id});
      if (previousError) throw previousError;
      const previous = (previousData ?? {found:false}) as PreviousImage;

      const image = await fetchLineImage(item.line_message_id);
      const { data: contexts, error: contextsError } = await client.from('child_school_contexts').select('id,school_display_name,class_display_name,recognition_aliases').eq('household_id',item.household_id);
      if (contextsError) throw contextsError;
      const analysis = await analyzeImage(image.bytes,image.contentType,(contexts ?? []) as ContextRow[],previous.found === true);
      if (analysis.triage === 'ordinary_photo') {
        const { data: finishedOrdinary, error: finishError } = await client.rpc('server_tx_finish_nursery_image_review',{ p_intake_id:item.id,p_expected_revision:currentRevision,p_status:'ordinary_photo',p_source_document_id:null,p_extraction_id:null,p_child_school_context_id:null,p_context_confidence:null,p_ambiguity_fields:[],p_review_items:[],p_raw_deleted:true });
        if (finishError) throw finishError;
        currentRevision = Number(finishedOrdinary?.revision ?? currentRevision);
        processed++; continue;
      }
      const ext = image.contentType.includes('png')?'png':image.contentType.includes('webp')?'webp':image.contentType.includes('heic')?'heic':'jpg';
      const objectKey = `${item.household_id}/${item.id}.${ext}`;
      const { error: uploadError } = await client.storage.from('nursery-source').upload(objectKey,image.bytes,{contentType:image.contentType,upsert:false});
      if (uploadError) throw uploadError;
      const { data: prepared, error: prepareError } = await client.rpc('server_tx_prepare_nursery_line_source',{p_intake_id:item.id,p_expected_revision:currentRevision,p_storage_object_key:objectKey,p_parser_version:'nursery-line-v1'});
      if (prepareError) throw prepareError;
      currentRevision = Number(prepared.revision);
      const status = analysis.ambiguous_fields.length > 0 || analysis.triage === 'needs_clarification' ? 'needs_clarification' : 'review_ready';
      const { data: finished, error: recordError } = await client.rpc('server_tx_record_nursery_line_analysis',{p_intake_id:item.id,p_expected_revision:currentRevision,p_child_school_context_id:analysis.child_school_context_id,p_context_confidence:analysis.context_confidence,p_ambiguity_fields:analysis.ambiguous_fields,p_source_facts:[],p_ai_candidates:[],p_review_items:analysis.review_items,p_status:status});
      if (recordError) throw recordError;
      currentRevision = Number(finished.revision);

      if (previous.found && previous.intake_id && previous.received_at && mayGroupNurseryPages({
        sameDocumentAsPrevious:analysis.same_document_as_previous,
        sameHousehold:true,
        sameLineUser:true,
        elapsedSeconds:(Date.parse(item.received_at)-Date.parse(previous.received_at))/1000,
        currentPageCount:Math.max(1,Number(previous.page_index ?? 1)),
      })) {
        const { data: grouped, error: groupError } = await client.rpc('server_tx_group_nursery_image_pages',{p_previous_id:previous.intake_id,p_current_id:item.id,p_expected_current_revision:currentRevision});
        if (groupError) console.warn('nursery grouping deferred', { intakeId:item.id,message:groupError.message });
        else currentRevision = Number(grouped?.revision ?? currentRevision);
      }
      processed++;
    } catch (err) {
      console.error('process-nursery-image-intake failed',{intakeId:item.id,message:err instanceof Error?err.message:String(err)});
      try {
        await client.rpc('server_tx_finish_nursery_image_review',{p_intake_id:item.id,p_expected_revision:currentRevision,p_status:'failed',p_source_document_id:null,p_extraction_id:null,p_child_school_context_id:null,p_context_confidence:null,p_ambiguity_fields:[],p_review_items:[],p_raw_deleted:false});
      } catch { /* already-terminal/stale rows remain auditable; processing rows use the latest known revision */ }
    }
  }
  return jsonResponse({claimed:claimed.length,processed});
}));