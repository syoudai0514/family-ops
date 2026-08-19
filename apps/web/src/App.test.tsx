import { render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import App from './App';

describe('App', () => {
  it('renders the Family Ops shell and resolves the Supabase connection check', async () => {
    render(<App />);
    expect(screen.getByRole('heading', { name: 'Family Ops' })).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.getByTestId('connection-state')).toHaveTextContent(
        'Supabase connection: ready',
      );
    });
  });
});
