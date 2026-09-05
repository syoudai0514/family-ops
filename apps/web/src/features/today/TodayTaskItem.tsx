import { Fragment } from 'react';
import { TaskChecklistItem, type TaskChecklistItemProps } from '../tasks/TaskChecklistItem';
import type { TaskExecutionTarget } from './useTodayData';

export type TodayTaskItemProps = TaskChecklistItemProps & {
  executionTarget?: TaskExecutionTarget | null;
};

export function TodayTaskItem({ executionTarget, ...props }: TodayTaskItemProps) {
  return (
    <Fragment>
      <TaskChecklistItem {...props} />
      {executionTarget && (
        <li className="task-execution-target-row" aria-label={`${props.task.title}の実行先`}>
          <span className="task-item-meta">実行先</span>
          {executionTarget.target_kind === 'url' && executionTarget.url ? (
            <a href={executionTarget.url} target="_blank" rel="noreferrer">
              {executionTarget.label || 'リンクを開く'}
            </a>
          ) : (
            <span>{executionTarget.destination}</span>
          )}
        </li>
      )}
    </Fragment>
  );
}
