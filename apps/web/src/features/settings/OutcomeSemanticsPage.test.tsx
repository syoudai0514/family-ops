import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it } from 'vitest';
import { OUTCOME_CHOICES, OutcomeSemanticsPage } from './OutcomeSemanticsPage';

describe('OutcomeSemanticsPage', () => {
  it('keeps mistaken existence distinct from occurrence outcomes', () => {
    render(<MemoryRouter><OutcomeSemanticsPage /></MemoryRouter>);

    expect(screen.getByRole('heading', { name: '消す前に、何を直したい？' })).toBeInTheDocument();
    expect(OUTCOME_CHOICES.map((choice) => choice.title)).toEqual([
      '項目そのものが間違い',
      '予定は正しいが、今回はやらなかった',
      '別の日にやる',
      '結果を付け間違えた',
    ]);
    expect(screen.getByText(/同じ削除にしません/)).toBeInTheDocument();
    expect(screen.getByText(/キャンセル・できなかった・今回は不要・再予定は別の結果/)).toBeInTheDocument();
  });

  it('routes every semantic choice to an existing operational surface', () => {
    render(<MemoryRouter><OutcomeSemanticsPage /></MemoryRouter>);
    for (const choice of OUTCOME_CHOICES) {
      expect(screen.getByRole('link', { name: new RegExp(choice.title) })).toHaveAttribute('href', choice.to);
    }
  });
});
