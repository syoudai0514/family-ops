import { taskRecordingLabel, type TaskRecordingSummary } from './taskRecording';
import './TaskRecordingBadge.css';

export function TaskRecordingBadge({
  summary,
  future = false,
}: {
  summary: TaskRecordingSummary;
  future?: boolean;
}) {
  const symbol =
    summary.state === 'completed'
      ? '✓'
      : summary.state === 'recorded'
        ? '−'
        : summary.state === 'pending'
          ? '·'
          : '—';
  return (
    <span className={`task-recording-badge ${summary.state} ${future ? 'future' : ''}`}>
      <span aria-hidden="true">{symbol}</span> {taskRecordingLabel(summary, future)}
    </span>
  );
}
