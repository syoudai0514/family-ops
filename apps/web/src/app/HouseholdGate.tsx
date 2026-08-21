import { useHousehold } from './HouseholdContext';
import { HouseholdSetup } from '../features/household/HouseholdSetup';
import { DropoffPickupStep } from '../features/household/DropoffPickupStep';
import { EveningRoutinesStep } from '../features/household/EveningRoutinesStep';
import { AppShell } from './AppShell';
import { LoadingScreen } from '../components/LoadingScreen';
import { InviteSection } from '../features/household/InviteSection';

// Household-level gating: no household -> setup/invite; household exists
// but the two-step wizard isn't finished -> the relevant wizard step;
// otherwise -> the full app. See HouseholdContext's phaseForHousehold for
// exactly how "finished" is determined.
export function HouseholdGate() {
  const { phase, loadError, refresh } = useHousehold();

  switch (phase) {
    case 'loading':
      return <LoadingScreen />;
    case 'error':
      return (
        <main className="app-shell centered" role="alert">
          <h1>家庭情報を読み込めませんでした</h1>
          <p>{loadError ?? '通信状態を確認して、もう一度お試しください。'}</p>
          <button type="button" onClick={() => void refresh()}>
            もう一度読み込む
          </button>
        </main>
      );
    case 'no-household':
      return <HouseholdSetup />;
    case 'partner-invite':
      return (
        <main className="app-shell">
          <p className="eyebrow">初期設定 2 / 8</p>
          <h1>パートナーを招待</h1>
          <p>担当を決める前に、パートナーに参加してもらいます。</p>
          <InviteSection />
          <button type="button" className="secondary-button" onClick={() => void refresh()}>
            参加状況を確認
          </button>
        </main>
      );
    case 'dropoff-pickup-wizard':
      return <DropoffPickupStep />;
    case 'evening-routines-wizard':
      return <EveningRoutinesStep />;
    case 'ready':
      return <AppShell />;
    default:
      return <LoadingScreen />;
  }
}
