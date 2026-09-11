import { Today } from './Today';

/**
 * Route-level compatibility wrapper.
 *
 * Today used to be rendered twice: this component independently fetched and
 * interpreted household state, then rendered <Today /> underneath it.  The
 * approved DailyBrief contract requires a single semantic owner, so /today has
 * exactly one controller now.
 */
export function TodayContractPage() {
  return <Today />;
}
