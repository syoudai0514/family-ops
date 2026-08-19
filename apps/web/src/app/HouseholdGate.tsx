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
  const { phase } = useHousehold();

  switch (phase) {
    case 'loading':
      return <LoadingScreen />;
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
