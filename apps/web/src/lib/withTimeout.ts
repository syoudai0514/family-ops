export class ClientTimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ClientTimeoutError';
  }
}

export function withTimeout<T>(
  promise: PromiseLike<T>,
  timeoutMs: number,
  message = '通信に時間がかかっています。もう一度お試しください。',
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;

  return new Promise<T>((resolve, reject) => {
    timer = setTimeout(() => reject(new ClientTimeoutError(message)), timeoutMs);

    Promise.resolve(promise).then(
      (value) => {
        if (timer) clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        if (timer) clearTimeout(timer);
        reject(error);
      },
    );
  });
}
