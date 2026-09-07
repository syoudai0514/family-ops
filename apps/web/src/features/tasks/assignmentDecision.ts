import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

export type AssignmentDecision = 'agreed' | 'request';

export function assignmentDecisionCommand(input: {
  decision: AssignmentDecision;
  operationId: string;
  taskId: string;
  assigneeUserId: string;
  expectedRevision: number;
  sharedMessage?: string;
}) {
  if (input.decision === 'agreed') {
    return {
      endpoint: EDGE_FUNCTIONS.changeTaskAssignment,
      body: {
        operation_id: input.operationId,
        task_id: input.taskId,
        assignee_user_id: input.assigneeUserId,
        already_agreed: true,
        expected_revision: input.expectedRevision,
      },
    } as const;
  }
  return {
    endpoint: EDGE_FUNCTIONS.createAssignmentChangeRequest,
    body: {
      operation_id: input.operationId,
      task_id: input.taskId,
      recipient_user_id: input.assigneeUserId,
      scope: 'once',
      shared_message: input.sharedMessage?.trim() || undefined,
    },
  } as const;
}
