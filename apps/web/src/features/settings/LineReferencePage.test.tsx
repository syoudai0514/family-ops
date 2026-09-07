import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it } from 'vitest';
import { LINE_ENTRY_POINTS, LineReferencePage } from './LineReferencePage';

describe('LineReferencePage', () => {
  it('keeps the exact six LINE fixed entry labels and functional PWA destinations', () => {
    render(<MemoryRouter><LineReferencePage /></MemoryRouter>);

    expect(screen.getByRole('heading', { name: '回答する場所: PWA / LINE' })).toBeInTheDocument();
    expect(LINE_ENTRY_POINTS.map((entry) => entry.label)).toEqual(['今日', '入力', '追加', 'お願い', '共有', 'その他']);

    for (const entry of LINE_ENTRY_POINTS) {
      const link = screen.getByRole('link', { name: new RegExp(`^${entry.label}`) });
      expect(link).toHaveAttribute('href', entry.to);
      expect(screen.getByText(new RegExp(`LINE: 「${entry.message}」`))).toBeInTheDocument();
    }
  });

  it('states that seven individual outcomes share canonical truth across PWA and LINE', () => {
    render(<MemoryRouter><LineReferencePage /></MemoryRouter>);

    expect(screen.getByText(/完了・相手が対応・できなかった・今回は不要・中止・再予定・不明/)).toBeInTheDocument();
    expect(screen.getByText(/別の実績コピーは作りません/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'PWAで入力する' })).toHaveAttribute('href', '/today?entry=checkin');
    expect(screen.getByRole('link', { name: '履歴で結果を確認' })).toHaveAttribute('href', '/history');
  });
});
