import { Fragment } from 'react';
import { TaskChecklistItem, type TaskChecklistItemProps } from '../tasks/TaskChecklistItem';
import type { TaskExecutionTarget } from './useTodayData';

export type TodayTaskItemProps = TaskChecklistItemProps & {
  executionTarget?: TaskExecutionTarget | null;
};

export function TodayTaskItem({ executionTarget, ...props }: TodayTaskItemProps) {
  const target = executionTarget ?? (
    props.task as typeof props.task & { execution_target?: TaskExecutionTarget | null }
  ).execution_target ?? null;

  return (
    <Fragment>
      <TaskChecklistItem {...props} />
      {target && (
        <li className="task-execution-target-row" aria-label={`${props.task.title}の実行先`}>
          <span className="task-item-meta">実行先</span>
          {target.target_kind === 'url' && target.url ? (
            <a href={target.url} target="_blank" rel="noreferrer">
              {target.label || 'リンクを開く'}
            </a>
          ) : (
            <span>{target.destination}</span>
          )}
        </li>
      )}
    </Fragment>
  );
}
