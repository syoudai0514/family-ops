// Q89-Q106 worker. Reads LINE images and replies to their sender; push
// fallbacks remain owned by the durable notification worker. Canonical changes remain behind the
// authenticated human-confirm endpoint.
import { createServiceRoleClient, requireWorkerToken } from '../_shared/auth.ts';
import { jsonResponse, withServiceHandler } from '../_shared/handler.ts';
import { buildNurseryResultMessage, mayGroupNurseryPages, nurseryFailureCode, type NurseryResultKind } from '../_shared/nurseryImage.ts';

import { analyzeImage, nurseryVisionModel, type ContextRow, type ModelResult } from './nurseryVision.ts';
import { replyOrEnqueuePush } from '../_shared/lineMessaging.ts';
import { kickNotificationDelivery } from './nurseryDelivery.ts';

type Claimed = {
  id: string; provider_event_id: string; line_message_id: string; household_id: string;
  actor_id: string; line_user_id: string; revision: number; received_at: string;
};
type PreviousImage = { found: boolean; intake_id?: string; received_at?: string; page_index?: number | null };

const WORKER_ID = `process-nursery-image-intake:${crypto.randomUUID()}`;

async function fetchLineImage(messageId: string): Promise<{ bytes: Uint8Array; contentType: string }> {
  const token = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN') ?? '';
  if (!token) throw new Error('LINE_CHANNEL_ACCESS_TOKEN_MISSING');
  const response = await fetch(`https://api-data.line.me/v2/bot/message/${encodeURIComponent(messageId)}/content`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10_000) });
  if (!response.ok) throw new Error(`LINE_CONTENT_HTTP_${response.status}`);
  const length = Number(response.headers.get('content-length') ?? '0');
  if (length > 10 * 1024 * 1024) throw new Error('NURSERY_IMAGE_TOO_LARGE');
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength > 10 * 1024 * 1024) throw new Error('NURSERY_IMAGE_TOO_LARGE');
  return { bytes, contentType: response.headers.get('content-type') ?? 'image/jpeg' };
}

// Tells the sender what happened to their photo. Best effort: a failed
// notification must never fail or re-run the intake itself.
async function notifySender(
  client: ReturnType<typeof createServiceRoleClient>,
  item: Claimed,
  kind: NurseryResultKind,
  itemCount: number,
  hasContexts: boolean,
): Promise<void> {
  try {
    const base = (Deno.env.get('APP_BASE_URL') ?? '').replace(/\/$/, '');
    const { data: delivery, error: deliveryError } = await client.rpc('server_read_nursery_line_delivery_context', {p_intake_id:item.id});
    if (deliveryError) console.warn('nursery delivery context unavailable', {code:nurseryFailureCode(deliveryError)});
    const result = await replyOrEnqueuePush(client, {
      replyToken: delivery?.reply_token,
      lineUserId: item.line_user_id,
      householdId: item.household_id,
      recipientUserId: item.actor_id,
      text: buildNurseryResultMessage({ kind, itemCount, hasContexts, link: base ? `${base}/nursery/reviews/${item.id}` : '' }),
      dedupKey: `nursery-intake:${item.id}:${kind}`,
    });
    if (result === 'push_fallback') await kickNotificationDelivery();
    console.info('nursery result delivery', {intakeId:item.id,delivery:result});
  } catch (err) {
    console.warn('process-nursery-image-intake: sender notice failed', { message: err instanceof Error ? err.message : String(err) });
  }
}


async function validateReviewItems(client: ReturnType<typeof createServiceRoleClient>, analysis: ModelResult): Promise<void> {
  if (!analysis.review_items.length) return;
  const {data, error} = await client.rpc('server_read_validate_nursery_review_items', {p_items:analysis.review_items});
  if (error) throw error;
  if (!data?.items?.length) throw new Error('NURSERY_REVIEW_ITEMS_INVALID');
  if (data.dropped > 0) console.warn('nursery invalid candidates withheld', {count:data.dropped});
  analysis.review_items = data.items;
}

// Worker-authenticated, read-only release check against an already stored image.
// Never creates reviews, sends LINE, or returns notice content in the response.
async function validateStoredImage(client: ReturnType<typeof createServiceRoleClient>, intakeId: unknown): Promise<Response> {
  if (typeof intakeId !== 'string' || !/^[0-9a-f-]{36}$/i.test(intakeId)) return jsonResponse({error:'INVALID_INPUT'},400);
  if (Deno.env.get('TEST_MODE') === '1') throw new Error('TEST_MODE_PROVIDER_READ_DISABLED');
  const startedAt = performance.now();
  const {data: source, error} = await client.rpc('server_read_nursery_line_delivery_context', {p_intake_id:intakeId});
  if (error) throw error;
  if (!source?.object_key) return jsonResponse({error:'NURSERY_SOURCE_UNAVAILABLE'},404);
  const {data: image, error: imageError} = await client.storage.from('nursery-source').download(source.object_key);
  if (imageError) throw imageError;
  const {data: contexts, error: contextError} = await client.from('child_school_contexts').select('id,school_display_name,class_display_name,recognition_aliases').eq('household_id',source.household_id).eq('active',true);
  if (contextError) throw contextError;
  const analysis = await analyzeImage(new Uint8Array(await image.arrayBuffer()),image.type || 'image/jpeg',contexts ?? [],false,source.received_at);
  await validateReviewItems(client,analysis);
  return jsonResponse({validated:true,model:nurseryVisionModel(),triage:analysis.triage,item_count:analysis.review_items.length,item_kinds:analysis.review_items.map(i=>i.item_kind),elapsed_ms:Math.round(performance.now()-startedAt)});
}

export const nurseryHandler = withServiceHandler(async (req: Request) => {
  requireWorkerToken(req);
  const client = createServiceRoleClient();
  const requested = await req.json().catch(() => ({}));
  const options = requested && typeof requested === 'object' ? requested : {};
  if (options.validation_intake_id) return await validateStoredImage(client, options.validation_intake_id);
  const { data, error } = await client.rpc('server_tx_claim_nursery_line_images', { p_limit: 3, p_worker: WORKER_ID });
  if (error) throw error;
  const claimed = ((data ?? []) as Claimed[]).sort((a,b) => Date.parse(a.received_at)-Date.parse(b.received_at));
  let processed=0;
  // At most three independent analyses run together, so one slow page does not
  // hold up another sender/page. Grouping follows persistence, in source order.
  const completed = await Promise.all(claimed.map(async (item) => {
    const startedAt = performance.now();
    let currentRevision = item.revision;
    try {
      if (Deno.env.get('TEST_MODE') === '1') throw new Error('TEST_MODE_PROVIDER_READ_DISABLED');
      const { data: previousData, error: previousError } = await client.rpc('server_read_previous_nursery_image',{p_current_id:item.id});
      if (previousError) throw previousError;
      const previous = (previousData ?? {found:false}) as PreviousImage;

      const image = await fetchLineImage(item.line_message_id);
      const { data: contexts, error: contextsError } = await client.from('child_school_contexts').select('id,school_display_name,class_display_name,recognition_aliases').eq('household_id',item.household_id).eq('active',true);
      if (contextsError) throw contextsError;
      const analysis = await analyzeImage(image.bytes,image.contentType,(contexts ?? []) as ContextRow[],previous.found === true,item.received_at);
      await validateReviewItems(client, analysis);
      console.info('nursery image analyzed', {intakeId:item.id,model:nurseryVisionModel(),elapsedMs:Math.round(performance.now()-startedAt),itemCount:analysis.review_items.length});
      if (analysis.triage === 'ordinary_photo') {
        const { data: finishedOrdinary, error: finishError } = await client.rpc('server_tx_finish_nursery_image_review',{ p_intake_id:item.id,p_expected_revision:currentRevision,p_status:'ordinary_photo',p_source_document_id:null,p_extraction_id:null,p_child_school_context_id:null,p_context_confidence:null,p_ambiguity_fields:[],p_review_items:[],p_raw_deleted:true });
        if (finishError) throw finishError;
        currentRevision = Number(finishedOrdinary?.revision ?? currentRevision);
        processed++; return null;
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
      await notifySender(client, item, status === 'needs_clarification' ? 'needs_clarification' : 'review_ready', analysis.review_items.length, (contexts ?? []).length > 0);

      processed++;
      return {item,analysis,previous,currentRevision};
    } catch (err) {
      console.error('process-nursery-image-intake failed',{intakeId:item.id,code:nurseryFailureCode(err)});
      try {
        await client.rpc('server_tx_finish_nursery_image_review',{p_intake_id:item.id,p_expected_revision:currentRevision,p_status:'failed',p_source_document_id:null,p_extraction_id:null,p_child_school_context_id:null,p_context_confidence:null,p_ambiguity_fields:[],p_review_items:[],p_raw_deleted:false});
      } catch { /* already-terminal/stale rows remain auditable; processing rows use the latest known revision */ }
      await notifySender(client, item, 'failed', 0, true);
      return null;
    }
  }));
  for (const result of completed) {
    if (!result) continue;
    const {item,analysis,previous} = result;
    const {currentRevision} = result;
      if (previous.found && previous.intake_id && previous.received_at && mayGroupNurseryPages({
        sameDocumentAsPrevious:analysis.same_document_as_previous,
        sameHousehold:true,
        sameLineUser:true,
        elapsedSeconds:(Date.parse(item.received_at)-Date.parse(previous.received_at))/1000,
        currentPageCount:Math.max(1,Number(previous.page_index ?? 1)),
      })) {
        const { data: grouped, error: groupError } = await client.rpc('server_tx_group_nursery_image_pages',{p_previous_id:previous.intake_id,p_current_id:item.id,p_expected_current_revision:currentRevision});
        if (groupError) console.warn('nursery grouping deferred', { intakeId:item.id,message:groupError.message });
        else if (!grouped) console.warn('nursery grouping returned no result');
      }
  }
  return jsonResponse({claimed:claimed.length,processed});
});

Deno.serve(nurseryHandler);
