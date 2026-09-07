import { describe, expect, it } from 'vitest';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { assignmentDecisionCommand } from './assignmentDecision';

describe('assignment decision semantics', () => {
  it('uses direct assignment only when the user says it is already agreed', () => {
    expect(assignmentDecisionCommand({
      decision: 'agreed', operationId: 'op-1', taskId: 'task-1', assigneeUserId: 'user-2', expectedRevision: 7,
    })).toEqual({
      endpoint: EDGE_FUNCTIONS.changeTaskAssignment,
      body: {
        operation_id: 'op-1', task_id: 'task-1', assignee_user_id: 'user-2', already_agreed: true, expected_revision: 7,
      },
    });
  });

  it('creates a request instead of silently reassigning when agreement is not established', () => {
    expect(assignmentDecisionCommand({
      decision: 'request', operationId: 'op-2', taskId: 'task-1', assigneeUserId: 'user-2', expectedRevision: 7, sharedMessage: ' お願いできますか？ ',
    })).toEqual({
      endpoint: EDGE_FUNCTIONS.createAssignmentChangeRequest,
      body: {
        operation_id: 'op-2', task_id: 'task-1', recipient_user_id: 'user-2', scope: 'once', shared_message: 'お願いできますか？',
      },
    });
  });
});
