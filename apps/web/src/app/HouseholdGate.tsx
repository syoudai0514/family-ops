import { useHousehold } from './HouseholdContext';
import { HouseholdSetup } from '../features/household/HouseholdSetup';
import { DropoffPickupStep } from '../features/household/DropoffPickupStep';
import { EveningRoutinesStep } from '../features/household/EveningRoutinesStep';
import { AppShell } from './AppShell';
import { LoadingScreen } from '../components/LoadingScreen';

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
