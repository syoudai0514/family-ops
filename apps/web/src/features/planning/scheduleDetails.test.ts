import { describe, expect, it } from 'vitest';
import { validateScheduleFiles, SCHEDULE_FILE_MAX_BYTES } from './scheduleDetails';
describe('schedule attachments', () => {
  it('allows a nursery PDF and image, and rejects oversized or executable files', () => {
    expect(validateScheduleFiles([new File(['notice'], '園の案内.pdf', { type: 'application/pdf' }), new File(['image'], 'photo.jpg', { type: 'image/jpeg' })])).toBeNull();
    expect(validateScheduleFiles([new File(['code'], 'program.exe', { type: 'application/octet-stream' })])).toContain('対応していません');
    expect(validateScheduleFiles([{ name: 'big.pdf', type: 'application/pdf', size: SCHEDULE_FILE_MAX_BYTES + 1 } as File])).toContain('10MB');
  });
});
