import { Navigate, Route, Routes } from 'react-router-dom';
import { HouseholdProvider } from './HouseholdContext';
import { HouseholdGate } from './HouseholdGate';

// Kept behind a dynamic import so an unauthenticated iPhone only needs the
// compact sign-in bundle. The household screens pull in the complete manual
// PWA and are not useful until a session exists.
export default function AuthenticatedApp() {
  return (
    <HouseholdProvider>
      <Routes>
        <Route path="/auth/callback" element={<Navigate to="/" replace />} />
        <Route path="*" element={<HouseholdGate />} />
      </Routes>
    </HouseholdProvider>
  );
}
