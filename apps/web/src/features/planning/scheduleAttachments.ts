import { supabase } from '../../lib/supabaseClient';
import { newOperationId } from '../../lib/id';
import { SCHEDULE_ATTACHMENT_BUCKET, validateScheduleFiles } from './scheduleDetails';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

const uploads = new WeakMap<File, { operationId: string; path: string; uploaded: boolean }>();

export async function uploadScheduleAttachment(householdId: string, taskId: string, file: File) {
  const invalid = validateScheduleFiles([file]);
  if (invalid) throw new Error(invalid);
  let upload = uploads.get(file);
  if (!upload || !upload.path.startsWith(`${householdId}/${taskId}/`)) {
    const operationId = newOperationId();
    upload = { operationId, path: `${householdId}/${taskId}/${operationId}`, uploaded: false };
    uploads.set(file, upload);
  }
  if (!upload.uploaded) {
    const { error } = await supabase.storage
      .from(SCHEDULE_ATTACHMENT_BUCKET)
      .upload(upload.path, file, { contentType: file.type, upsert: false });
    if (error && !/already exists|duplicate/i.test(error.message)) throw error;
    upload.uploaded = true;
  }
  await callEdgeFunction(EDGE_FUNCTIONS.editTask, {
    operation_id: upload.operationId,
    sharing_action: 'register_attachment',
    task_id: taskId,
    file_name: file.name,
    object_path: upload.path,
    mime_type: file.type,
    size_bytes: file.size,
  });
  uploads.delete(file);
}
