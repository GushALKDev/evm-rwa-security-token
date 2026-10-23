/** The call a button sends and, when it reaches the desk, the calls the desk makes in turn. */
export function Calls({ call, then = [] }: { call: string; then?: string[] }) {
  return (
    <p className="hint calls">
      Calls <span className="mono">{call}</span>
      {then.length > 0 ? ', which calls ' : null}
      {then.map((c, i) => (
        <span key={c}>
          {i > 0 ? (i === then.length - 1 ? ' and ' : ', ') : null}
          <span className="mono">{c}</span>
        </span>
      ))}
      .
    </p>
  )
}
