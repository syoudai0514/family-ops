import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { PushSection } from './PushSection';

const push = vi.hoisted(() => ({
  pushAvailability: vi.fn(),
  notificationPermission: vi.fn(),
  fetchPushConfig: vi.fn(),
  isPushEnabledHere: vi.fn(),
  enablePush: vi.fn(),
  disablePush: vi.fn(),
  sendTestPush: vi.fn(),
}));
vi.mock('../../lib/webPush', () => push);

describe('PushSection', () => {
  beforeEach(() => {
    Object.values(push).forEach((fn) => fn.mockReset());
    push.pushAvailability.mockReturnValue('supported');
    push.notificationPermission.mockReturnValue('default');
    push.fetchPushConfig.mockResolvedValue({ enabled: true, publicKey: 'key' });
    push.isPushEnabledHere.mockResolvedValue(false);
  });

  it('explains the home-screen step on iPhone Safari', async () => {
    push.pushAvailability.mockReturnValue('needs-home-screen');
    render(<PushSection />);
    expect(await screen.findByText('「ホーム画面に追加」を選ぶ')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'この端末で通知を受け取る' })).not.toBeInTheDocument();
  });

  it('turns push on from a tap and offers a test notification', async () => {
    push.enablePush.mockResolvedValue('enabled');
    push.sendTestPush.mockResolvedValue('sent');
    render(<PushSection />);
    fireEvent.click(await screen.findByRole('button', { name: 'この端末で通知を受け取る' }));
    expect(await screen.findByText('✓ この端末で予定の通知を受け取ります。')).toBeInTheDocument();
    expect(push.enablePush).toHaveBeenCalledWith('key');
    fireEvent.click(screen.getByRole('button', { name: 'テスト通知を送る' }));
    expect(await screen.findByText(/テスト通知を送りました/)).toBeInTheDocument();
  });

  it('points to the device settings when notifications were refused', async () => {
    push.enablePush.mockResolvedValue('denied');
    render(<PushSection />);
    fireEvent.click(await screen.findByRole('button', { name: 'この端末で通知を受け取る' }));
    expect(await screen.findByText(/通知が許可されていません/)).toBeInTheDocument();
  });

  it('falls back to LINE when push is not configured on the server', async () => {
    push.fetchPushConfig.mockResolvedValue({ enabled: false, publicKey: null });
    render(<PushSection />);
    expect(await screen.findByText(/まだ使えません。予定の通知はLINEで届きます/)).toBeInTheDocument();
  });
});
