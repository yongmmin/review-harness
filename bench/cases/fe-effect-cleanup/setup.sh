#!/bin/bash
# Next.js app: the session banner starts refreshing itself through a new useNow hook.
set -eu
. "$(cd "$(dirname "$0")/../.." && pwd)/lib.sh"
D="${1:-}"; bench_init "$D"; cd "$D"
mkdir -p src/app src/components/SessionExpiryBanner src/hooks src/lib

# --- before ---------------------------------------------------------------------------
cat > package.json <<'EOF'
{
  "name": "web",
  "private": true,
  "scripts": { "dev": "next dev", "build": "next build", "test": "vitest run" },
  "dependencies": { "next": "14.2.5", "react": "18.3.1", "react-dom": "18.3.1" },
  "devDependencies": { "@types/react": "18.3.3", "typescript": "5.5.4", "vitest": "2.0.5" }
}
EOF
cat > tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "strict": true,
    "jsx": "preserve",
    "module": "esnext",
    "moduleResolution": "bundler",
    "baseUrl": ".",
    "paths": { "@/*": ["./src/*"] }
  }
}
EOF
cat > src/lib/time.ts <<'EOF'
const MS_PER_MINUTE = 60_000

export function minutesUntil(target: Date, now: Date): number {
  return Math.ceil((target.getTime() - now.getTime()) / MS_PER_MINUTE)
}
EOF
cat > src/components/SessionExpiryBanner/index.tsx <<'EOF'
export { SessionExpiryBanner } from './SessionExpiryBanner'
EOF
cat > src/components/SessionExpiryBanner/SessionExpiryBanner.tsx <<'EOF'
'use client'

import { minutesUntil } from '@/lib/time'

const WARN_THRESHOLD_MIN = 5

interface SessionExpiryBannerProps {
  expiresAt: string
  onExtend: () => void
}

export function SessionExpiryBanner({ expiresAt, onExtend }: SessionExpiryBannerProps) {
  const remaining = minutesUntil(new Date(expiresAt), new Date())
  if (remaining > WARN_THRESHOLD_MIN) return null

  return (
    <div role="status" className="flex items-center gap-2 rounded bg-amber-100 px-3 py-2 text-sm">
      <span>Your session expires in {remaining} min.</span>
      <button type="button" onClick={onExtend} className="font-medium underline">
        Stay signed in
      </button>
    </div>
  )
}
EOF
cat > src/app/layout.tsx <<'EOF'
import type { ReactNode } from 'react'
import { SessionShell } from './SessionShell'

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <SessionShell>{children}</SessionShell>
      </body>
    </html>
  )
}
EOF
cat > src/app/SessionShell.tsx <<'EOF'
'use client'

import type { ReactNode } from 'react'
import { SessionExpiryBanner } from '@/components/SessionExpiryBanner'
import { useSession } from '@/hooks/useSession'

export function SessionShell({ children }: { children: ReactNode }) {
  const { session, extend } = useSession()

  return (
    <>
      {session && <SessionExpiryBanner expiresAt={session.expiresAt} onExtend={extend} />}
      {children}
    </>
  )
}
EOF
cat > src/hooks/useSession.ts <<'EOF'
import { useCallback, useState } from 'react'

export interface Session {
  userId: string
  expiresAt: string
}

export function useSession(): { session: Session | null; extend: () => void } {
  const [session, setSession] = useState<Session | null>(null)

  const extend = useCallback(() => {
    setSession((current) =>
      current ? { ...current, expiresAt: new Date(Date.now() + 30 * 60_000).toISOString() } : current,
    )
  }, [])

  return { session, extend }
}
EOF
bench_base .

# --- after ----------------------------------------------------------------------------
cat > src/hooks/useNow.ts <<'EOF'
import { useEffect, useState } from 'react'

export function useNow(intervalMs: number): Date {
  const [now, setNow] = useState<Date>(() => new Date())

  useEffect(() => {
    const refresh = (): void => setNow(new Date())
    setInterval(refresh, intervalMs)
    document.addEventListener('visibilitychange', refresh)
  }, [intervalMs])

  return now
}
EOF
cat > src/components/SessionExpiryBanner/SessionExpiryBanner.tsx <<'EOF'
'use client'

import { useNow } from '@/hooks/useNow'
import { minutesUntil } from '@/lib/time'

const WARN_THRESHOLD_MIN = 5
const TICK_MS = 30_000

interface SessionExpiryBannerProps {
  expiresAt: string
  onExtend: () => void
}

export function SessionExpiryBanner({ expiresAt, onExtend }: SessionExpiryBannerProps) {
  const now = useNow(TICK_MS)
  const remaining = minutesUntil(new Date(expiresAt), now)
  if (remaining > WARN_THRESHOLD_MIN) return null

  return (
    <div role="status" className="flex items-center gap-2 rounded bg-amber-100 px-3 py-2 text-sm">
      {remaining > 0 ? (
        <span>Your session expires in {remaining} min.</span>
      ) : (
        <span>Your session has expired.</span>
      )}
      <button type="button" onClick={onExtend} className="font-medium underline">
        Stay signed in
      </button>
    </div>
  )
}
EOF
bench_done .
