// The family mark: the reference's four bars, recolored with this app's accent.
export function Mark() {
  return (
    <svg width="26" height="26" viewBox="0 0 32 32" aria-hidden="true">
      <rect width="32" height="32" rx="8" fill="var(--ink)" />
      <rect x="6" y="9" width="8" height="5" rx="1.5" fill="var(--mark-1)" />
      <rect x="15" y="9" width="11" height="5" rx="1.5" fill="var(--mark-2)" />
      <rect x="6" y="18" width="15" height="5" rx="1.5" fill="var(--mark-3)" />
      <rect x="22" y="18" width="4" height="5" rx="1.5" fill="var(--mark-4)" />
    </svg>
  )
}

export function ToastIcon({ tone }: { tone: 'pending' | 'success' | 'error' }) {
  if (tone === 'pending')
    return (
      <svg className="toast-icon" viewBox="0 0 18 18" aria-hidden="true">
        <circle cx="9" cy="9" r="7" fill="none" stroke="currentColor" strokeWidth="2" strokeDasharray="30 14" />
      </svg>
    )
  if (tone === 'success')
    return (
      <svg className="toast-icon" viewBox="0 0 18 18" aria-hidden="true">
        <circle cx="9" cy="9" r="8" fill="currentColor" />
        <path d="M5.5 9.2l2.3 2.3 4.7-4.9" fill="none" stroke="var(--surface)" strokeWidth="1.8" strokeLinecap="round" />
      </svg>
    )
  return (
    <svg className="toast-icon" viewBox="0 0 18 18" aria-hidden="true">
      <circle cx="9" cy="9" r="8" fill="currentColor" />
      <path d="M9 5v5M9 12.6v.1" stroke="var(--surface)" strokeWidth="1.9" strokeLinecap="round" />
    </svg>
  )
}

export function CloseIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
      <path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  )
}

/** Outcome glyphs for the gate's markers: drawn, not colored alone, so the outcome reads without color. */
export function OutcomeIcon({ outcome }: { outcome: 'pass' | 'fail' }) {
  return outcome === 'pass' ? (
    <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
      <path d="M3 7.3l2.6 2.6L11 4.4" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  ) : (
    <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
      <path d="M4 4l6 6M10 4l-6 6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  )
}
