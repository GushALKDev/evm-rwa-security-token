import { useState } from 'react'
import { hexToString, keccak256, type Hex } from 'viem'
import { explorerAddress, links } from '../config/chain'
import { countryLabel } from '../lib/countries'
import { perToken } from '../lib/dividends'
import { formatDate, formatDuration, formatEurc, shortAddress } from '../lib/format'
import type { ModuleRef } from '../lib/gate'
import type { TokenModel } from '../lib/model'

function moduleLine(m: ModuleRef, model: TokenModel): string {
  const g = model.gate
  switch (m.kind) {
    case 'maxHolders':
      return `Stops a transfer that would add a holder past the cap. ${g.holderCount.toString()} of ${g.maxHolders.toString()} today.`
    case 'country': {
      const restricted = [...g.restricted].filter(([, r]) => r).map(([code]) => countryLabel(code))
      return restricted.length
        ? `Stops tokens sent to a wallet resident in a restricted jurisdiction: ${restricted.join(', ')}.`
        : 'Stops tokens sent to a wallet resident in a restricted jurisdiction. None is restricted today.'
    }
    case 'lockup':
      return `Stops a sender within ${formatDuration(Number(g.lockupPeriod))} of its first tokens. The production script sets 365 days; this deployment shortened it through the module's own setter.`
    case 'distributor':
      return `Never stops anything: it watches transfers to split income. ${formatEurc(perToken(model.live.dividendsPerShare))} EURC paid per token since issuance.`
    default:
      return 'A module this page does not know.'
  }
}

export function RuleSetCard({ model }: { model: TokenModel }) {
  const g = model.gate
  const fill = g.maxHolders > 0n ? Number((g.holderCount * 10_000n) / g.maxHolders) / 100 : 0
  return (
    <div className="card">
      <div className="card-title">
        <h3>The rule set</h3>
        <a className="card-sub" href={explorerAddress(model.deployment.compliance)} target="_blank" rel="noreferrer">
          Compliance engine
        </a>
      </div>
      <p className="card-sub" style={{ marginBottom: 6 }}>
        Modules on the engine, in the order it asks them. Every one must pass, and the engine stops at the first that
        refuses. The token reports any refusal as the same ComplianceCheckFailed, so the gate above evaluates each
        module's own check to show which one it was.
      </p>
      <ol className="modules">
        {g.modules.map((m) => (
          <li key={m.address}>
            <a className="mono" href={explorerAddress(m.address)} target="_blank" rel="noreferrer">
              {model.static.moduleNames[m.address.toLowerCase()] ?? shortAddress(m.address)}
            </a>
            <p>{moduleLine(m, model)}</p>
            {m.kind === 'maxHolders' ? (
              <div className="cap-bar" role="meter" aria-label="Holders against the cap" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(fill)}>
                <span style={{ width: `${Math.max(fill, 0.5)}%` }} />
              </div>
            ) : null}
          </li>
        ))}
      </ol>
    </div>
  )
}

type Check = { state: 'idle' | 'checking' } | { state: 'done'; hash: Hex } | { state: 'error'; message: string }

export function TermsCard({ model }: { model: TokenModel }) {
  const t = model.static.terms
  const [check, setCheck] = useState<Check>({ state: 'idle' })
  const name = hexToString(model.deployment.termsName, { size: 32 }).replace(/\0+$/, '')

  const run = async () => {
    setCheck({ state: 'checking' })
    try {
      const res = await fetch(t.uri, { cache: 'no-store' })
      if (!res.ok) throw new Error(`The host answered ${res.status}.`)
      const bytes = new Uint8Array(await res.arrayBuffer())
      setCheck({ state: 'done', hash: keccak256(bytes) })
    } catch (err) {
      setCheck({ state: 'error', message: err instanceof Error ? err.message : 'The request failed.' })
    }
  }

  return (
    <div className="card" id="terms">
      <div className="card-title">
        <h3>The terms, anchored</h3>
        <a className="card-sub" href={explorerAddress(model.deployment.documentRegistry)} target="_blank" rel="noreferrer">
          Document registry
        </a>
      </div>
      <p className="card-sub">
        The registry stores a hash of the document's content, not just where it lives. Anyone can fetch the file and
        check that it is the version in force.
      </p>
      <dl className="rows">
        <div className="row">
          <dt>Name</dt>
          <dd className="mono">{name}</dd>
        </div>
        <div className="row">
          <dt>Anchored hash</dt>
          <dd className="mono" title={t.contentHash}>
            {shortAddress(t.contentHash)}
          </dd>
        </div>
        <div className="row">
          <dt>Anchored on</dt>
          <dd>{formatDate(t.lastModified)}</dd>
        </div>
        <div className="row">
          <dt>Published at</dt>
          <dd>
            <a href={t.uri} target="_blank" rel="noreferrer">
              {new URL(t.uri).hostname}
            </a>
          </dd>
        </div>
      </dl>
      <button className="btn" style={{ marginTop: 14 }} onClick={run} disabled={check.state === 'checking'}>
        {check.state === 'checking' ? 'Hashing the file…' : 'Hash the published file in this browser'}
      </button>
      {check.state === 'done' ? (
        check.hash === t.contentHash ? (
          <p className="hint" style={{ marginTop: 10 }}>
            The file hashes to <span className="mono">{shortAddress(check.hash)}</span>, the anchored hash: it is the
            version in force.
          </p>
        ) : (
          <p className="hint" data-tone="danger" style={{ marginTop: 10 }}>
            The file now hashes to <span className="mono">{shortAddress(check.hash)}</span>, not the anchored{' '}
            <span className="mono">{shortAddress(t.contentHash)}</span>: it changed after it was anchored.
          </p>
        )
      ) : null}
      {check.state === 'error' ? (
        <p className="hint" data-tone="danger" style={{ marginTop: 10 }}>
          Could not fetch the file: {check.message}
        </p>
      ) : null}
      <p className="hint" style={{ marginTop: 10 }}>
        <a href={links.terms} target="_blank" rel="noreferrer">
          Read the terms
        </a>
        : a mock document for this proof of concept, with no legal validity.
      </p>
    </div>
  )
}
