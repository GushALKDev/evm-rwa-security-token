import { Fragment, useMemo, useState } from 'react'
import { zeroAddress } from 'viem'
import { useConnection, useReadContract } from 'wagmi'
import { chain, explorerAddress, links } from '../config/chain'
import type { SeedKey } from '../config/deployment'
import { checkSource, engineSource, moduleSource, sourceUrl, type SourceAnchor } from '../config/source'
import { useParties, useRestricted, type PartyData } from '../hooks/useTokenData'
import { useTx } from '../hooks/useTx'
import { securityTokenAbi, tokenAbi } from '../lib/abi'
import { parseTypedAddress } from '../lib/address'
import { countryLabel } from '../lib/countries'
import { formatDate, formatDuration, formatEurc, formatTokenCount, formatTokens, parseAmount, shortAddress, solidityAmount, toInput } from '../lib/format'
import {
  evaluateGate,
  freeBalance,
  holderCountAfter,
  identityWhy,
  lockupEffect,
  type GateResult,
  type PartyState,
} from '../lib/gate'
import { labelOf, type TokenModel } from '../lib/model'
import { scenarioAmount, scenarios } from '../lib/scenarios'
import { Calls } from './Calls'
import { checkText, revertText } from './gateText'
import { OutcomeIcon } from './icons'

type Choice = 'you' | 'mint' | 'custom' | SeedKey

const TOKEN_DECIMALS = 18

function useCustomParty(input: string) {
  const typed = parseTypedAddress(input)
  const address = typed && 'address' in typed ? typed.address : null
  const list = useMemo(() => (address ? [address] : []), [address])
  const parties = useParties(list)
  return { address, party: address ? parties.data?.[0] : undefined, error: typed && 'error' in typed ? typed.error : null }
}

function PartyField({
  id,
  label,
  choice,
  onChoice,
  allowMint,
  connected,
  custom,
  onCustom,
  summary,
  model,
}: {
  id: string
  label: string
  choice: Choice
  onChoice: (c: Choice) => void
  allowMint: boolean
  connected: boolean
  custom: string
  onCustom: (v: string) => void
  summary: string
  model: TokenModel
}) {
  const typed = choice === 'custom' ? parseTypedAddress(custom) : null
  const invalid = typed && 'error' in typed ? typed.error : null
  return (
    <div className="field">
      <label className="field-label" htmlFor={id}>
        <span>{label}</span>
      </label>
      <select id={id} className="select" value={choice} onChange={(e) => onChoice(e.target.value as Choice)}>
        {connected ? <option value="you">Your wallet</option> : null}
        {allowMint ? <option value="mint">New issue (a mint)</option> : null}
        <optgroup label="Seeded wallets">
          {model.deployment.seeds.map((s) => (
            <option key={s.key} value={s.key}>
              {s.label}
            </option>
          ))}
        </optgroup>
        <option value="custom">Another address…</option>
      </select>
      {choice === 'custom' ? (
        <input
          className="text-input"
          aria-label={`${label} address`}
          placeholder="0x…"
          spellCheck={false}
          autoComplete="off"
          value={custom}
          onChange={(e) => onCustom(e.target.value)}
        />
      ) : null}
      <span className="hint" data-tone={invalid ? 'danger' : undefined}>
        {invalid ?? summary}
      </span>
    </div>
  )
}

/** One chip per seeded wallet: each sets the pair and the amount that show that wallet's outcome. */
function Cases({ model, active, onPick }: { model: TokenModel; active: SeedKey | null; onPick: (key: SeedKey) => void }) {
  const seed = model.deployment.seeds.find((s) => s.key === active)
  return (
    <div className="cases">
      <div className="choice" role="group" aria-label="Cases, one per seeded wallet">
        <span className="cases-label">Try a case</span>
        {model.deployment.seeds.map((s) => (
          <button key={s.key} className="chip" aria-pressed={s.key === active} onClick={() => onPick(s.key)}>
            {s.label}
          </button>
        ))}
      </div>
      <p className="hint">
        {seed
          ? `${seed.label}: ${seed.seeded.charAt(0).toLowerCase()}${seed.seeded.slice(1)}`
          : `Each case pairs a seeded wallet with another to show one outcome. No seeded wallet reaches the pause or the holder cap, which depend on the agent and on the register; the lockup stops your own wallet in its first ${formatDuration(Number(model.live.lockupPeriod))}.`}
      </p>
    </div>
  )
}

/** One line on a wallet: what it holds and where its identity stands, at the chain's time. */
function partySummary(p: PartyData | undefined, model: TokenModel): string {
  if (!p) return 'Reading the wallet…'
  const tokens = formatTokenCount(p.balance)
  const frozen = p.frozen ? ', wallet frozen' : p.frozenTokens > 0n ? `, ${formatTokens(p.frozenTokens)} frozen` : ''
  const why = identityWhy(p, model.chainTime)
  const id =
    why === 'verified'
      ? `verified in ${countryLabel(p.country)} until ${formatDate(p.kycExpiry)}`
      : why === 'lapsed'
        ? `KYC lapsed on ${formatDate(p.kycExpiry)}`
        : why === 'removed'
          ? 'identity removed'
          : 'not verified'
  return `${tokens}${frozen}, ${id}.`
}

export function Gate({ model, onConnect, onDesk }: { model: TokenModel; onConnect: () => void; onDesk: () => void }) {
  const { status, chainId } = useConnection()
  const d = model.deployment
  const acc = model.account
  const connected = status === 'connected' && chainId === chain.id && !!acc

  // Null means "the default", which depends on whether a wallet is connected.
  const [fromPick, setFromPick] = useState<Choice | null>(null)
  const [toPick, setToPick] = useState<Choice | null>(null)
  const [fromCustom, setFromCustom] = useState('')
  const [toCustom, setToCustom] = useState('')
  const [input, setInput] = useState('1')

  const fromChoice: Choice = fromPick && (fromPick !== 'you' || connected) ? fromPick : connected ? 'you' : 'settled'
  const toChoice: Choice = toPick && (toPick !== 'you' || connected) ? toPick : connected ? 'settled' : 'restricted'

  const customFrom = useCustomParty(fromCustom)
  const customTo = useCustomParty(toCustom)
  const extraCodes = useMemo(
    () => [customFrom.party?.country, customTo.party?.country].filter((c): c is number => c !== undefined),
    [customFrom.party?.country, customTo.party?.country],
  )
  const extraRestricted = useRestricted(extraCodes)

  const resolve = (choice: Choice, custom: ReturnType<typeof useCustomParty>): PartyData | null | undefined => {
    if (choice === 'mint') return null
    if (choice === 'you') return acc?.party
    if (choice === 'custom') return custom.party
    const seed = d.seeds.find((s) => s.key === choice)!
    return model.parties.get(seed.address.toLowerCase())
  }
  const from = resolve(fromChoice, customFrom)
  const to = resolve(toChoice, customTo) as PartyData | undefined
  const amount = parseAmount(input, TOKEN_DECIMALS)

  // A case is active whenever the inputs match it, however they were set.
  const activeCase =
    d.seeds.find(({ key }) => {
      const s = scenarios[key]
      return fromChoice === s.from && toChoice === s.to && !!from && amount === scenarioAmount(s, from.balance)
    })?.key ?? null
  const pickCase = (key: SeedKey) => {
    const s = scenarios[key]
    const sender = model.parties.get(d.seeds.find((x) => x.key === s.from)!.address.toLowerCase())
    setFromPick(s.from)
    setToPick(s.to)
    setInput(toInput(scenarioAmount(s, sender?.balance ?? 0n), TOKEN_DECIMALS))
  }

  const gateState = useMemo(() => {
    if (!extraRestricted.data) return model.gate
    return { ...model.gate, restricted: new Map([...model.gate.restricted, ...extraRestricted.data]) }
  }, [model.gate, extraRestricted.data])

  const result: GateResult | null =
    from !== undefined && to !== undefined && amount !== null
      ? evaluateGate(gateState, from, to, amount, model.chainTime)
      : null

  // The contract's own answer for the same inputs, as a live cross-check of the mirror.
  const onChain = useReadContract({
    address: d.token,
    abi: securityTokenAbi,
    functionName: 'canTransfer',
    args: [from ? from.address : zeroAddress, to?.address ?? zeroAddress, amount ?? 0n],
    query: { enabled: !!to && amount !== null, refetchInterval: 6_000 },
  })

  const maxFrom = from ? freeBalance(from) : null
  const summary = (choice: Choice, p: PartyData | null | undefined) =>
    choice === 'mint'
      ? 'Primary issuance: the issuer mints to the recipient. The desk issues test tokens this way.'
      : partySummary(p ?? undefined, model)

  return (
    <div className="sheet gate" id="gate">
      <div className="sheet-top">
        <h2>The transfer gate</h2>
        <a className="card-sub" href={explorerAddress(d.token)} target="_blank" rel="noreferrer">
          Read live from {chain.name}
        </a>
      </div>

      <Cases model={model} active={activeCase} onPick={pickCase} />

      <div className="gate-inputs">
        <PartyField
          id="gate-from"
          label="From"
          choice={fromChoice}
          onChoice={setFromPick}
          allowMint
          connected={connected}
          custom={fromCustom}
          onCustom={setFromCustom}
          summary={summary(fromChoice, from)}
          model={model}
        />
        <PartyField
          id="gate-to"
          label="To"
          choice={toChoice}
          onChoice={setToPick}
          allowMint={false}
          connected={connected}
          custom={toCustom}
          onCustom={setToCustom}
          summary={summary(toChoice, to)}
          model={model}
        />
        <div className="field">
          <label className="field-label" htmlFor="gate-amount">
            <span>Amount</span>
          </label>
          <div className="input-wrap input-compact" data-invalid={input !== '' && amount === null}>
            <input
              id="gate-amount"
              className="amount-input"
              inputMode="decimal"
              autoComplete="off"
              placeholder="0"
              value={input}
              onChange={(e) => setInput(e.target.value)}
            />
            <span className="unit">tokens</span>
            {maxFrom !== null && maxFrom > 0n ? (
              <button className="max" onClick={() => setInput(toInput(maxFrom, TOKEN_DECIMALS))}>
                Max
              </button>
            ) : null}
          </div>
          <span className="hint" data-tone={input !== '' && amount === null ? 'danger' : undefined}>
            {input !== '' && amount === null
              ? 'Enter a number with at most 18 decimals.'
              : maxFrom !== null
                ? `Free to move: ${formatTokens(maxFrom)}.`
                : 'A new issue has no sender balance to draw on.'}
          </span>
        </div>
      </div>

      {result && to ? (
        <Checks result={result} model={model} from={from ?? null} to={to} amount={amount!} />
      ) : (
        <p className="muted gate-pending">
          {amount === null ? 'Enter an amount to run the gate.' : 'Reading the wallets…'}
        </p>
      )}

      {result && to ? (
        <Verdict result={result} model={model} from={from ?? null} to={to} amount={amount!} onChain={onChain.data} />
      ) : null}

      {fromChoice === 'you' && connected && result && to && amount !== null ? (
        <Send model={model} result={result} to={to} amount={amount} onDesk={onDesk} />
      ) : !connected && status !== 'connected' ? (
        <p className="hint gate-foot">
          To send tokens of your own,{' '}
          <button className="link-button" onClick={onConnect}>
            connect a wallet
          </button>{' '}
          and get test tokens from the desk. The seeded wallets above are there to try every check without one.
        </p>
      ) : null}
    </div>
  )
}

function SourceLink({ anchor, children }: { anchor: SourceAnchor; children: string }) {
  return (
    <a className="mono faint check-contract" href={sourceUrl(anchor)} target="_blank" rel="noreferrer" title={`${anchor.path}, line ${anchor.from}`}>
      {children}
    </a>
  )
}

function Checks({
  result,
  model,
  from,
  to,
  amount,
}: {
  result: GateResult
  model: TokenModel
  from: PartyState | null
  to: PartyState
  amount: bigint
}) {
  const firstModule = result.checks.findIndex((c) => c.key === 'module')
  return (
    <ol className="checks" aria-label="Checks, in the order the contract runs them">
      {result.checks.map((c, i) => {
        const t = checkText(c, model, from, to, amount)
        const label =
          c.outcome === 'pass' ? 'Passes' : c.outcome === 'fail' ? 'Stops here' : c.outcome === 'skipped' ? 'Skipped' : 'Not reached'
        const anchor = c.module ? moduleSource[c.module.kind] : c.key !== 'module' ? checkSource[c.key] : undefined
        return (
          <Fragment key={i}>
            {i === 0 ? (
              <li className="checks-group">The token's own checks. Each contract name links to the line that runs the check.</li>
            ) : null}
            {i === firstModule ? (
              <li className="checks-group">
                Compliance engine, each module in registration order
                <SourceLink anchor={engineSource}>ModularCompliance</SourceLink>
              </li>
            ) : null}
            <li className="check" data-outcome={c.outcome}>
              <span className="check-marker" aria-hidden="true">
                {c.outcome === 'pass' || c.outcome === 'fail' ? <OutcomeIcon outcome={c.outcome} /> : i + 1}
              </span>
              <div className="check-body">
                <div className="check-title">
                  <span className="check-number">{i + 1}.</span> {t.title}
                  {anchor ? (
                    <SourceLink anchor={anchor}>{t.contract ?? 'SecurityToken'}</SourceLink>
                  ) : t.contract ? (
                    <span className="mono faint check-contract">{t.contract}</span>
                  ) : null}
                </div>
                <div className="check-detail">{t.detail}</div>
              </div>
              <span className="status" data-tone={c.outcome === 'pass' ? 'ok' : c.outcome === 'fail' ? 'danger' : undefined}>
                {label}
              </span>
            </li>
          </Fragment>
        )
      })}
    </ol>
  )
}

function Verdict({
  result,
  model,
  from,
  to,
  amount,
  onChain,
}: {
  result: GateResult
  model: TokenModel
  from: PartyState | null
  to: PartyState
  amount: bigint
  onChain: boolean | undefined
}) {
  const stopped = result.stoppedAt !== null ? result.checks[result.stoppedAt] : null
  const stoppedText = stopped ? checkText(stopped, model, from, to, amount) : null
  const agrees = onChain === undefined || result.ok === null ? null : onChain === result.ok
  return (
    <div className="verdict" data-tone={result.ok === true ? 'ok' : result.ok === false ? 'danger' : undefined} role="status">
      <p className="verdict-main">
        {result.ok === true ? (
          <>
            <strong>Clears the gate.</strong> {amount === 0n ? 'A zero amount passes the modules but still needs both parties verified and unfrozen.' : 'The contract would move the tokens.'}
          </>
        ) : result.ok === false && stopped && stoppedText ? (
          <>
            <strong>
              Stops at {result.stoppedAt! + 1}, {stoppedText.title.toLowerCase()}.
            </strong>{' '}
            The token reverts with <span className="mono">{revertText(result.revert!)}</span>
            {stopped.key === 'module' || stopped.key === 'unfrozen' ? ', amounts in base units of 18 decimals.' : '.'}
            {stopped.key === 'module' ? (
              <>
                {' '}
                The error does not say which module refused: this page found out by asking each module its own{' '}
                <span className="mono">moduleCheck</span>, in the engine's order.
              </>
            ) : null}
          </>
        ) : (
          <>
            <strong>A module this page does not mirror decides.</strong> The contract's answer is below.
          </>
        )}
      </p>
      <p className="verdict-check">
        <span className="mono">canTransfer</span> on {chain.name}:{' '}
        {onChain === undefined ? 'reading…' : onChain ? 'true' : 'false'}
        {agrees === true ? ', the same answer as the checks above.' : null}
        {agrees === false
          ? '. That differs from the checks above, which were read a moment apart; the next refresh reads both again.'
          : null}
      </p>
    </div>
  )
}

function Send({
  model,
  result,
  to,
  amount,
  onDesk,
}: {
  model: TokenModel
  result: GateResult
  to: PartyData
  amount: bigint
  onDesk: () => void
}) {
  const acc = model.account!
  const d = model.deployment
  const { run, busy } = useTx({ labelOf: (a) => labelOf(d, acc.address, a) })
  const noGas = acc.extras?.eth === 0n
  const self = to.address.toLowerCase() === acc.address.toLowerCase()
  const canSend = result.ok === true && amount > 0n && !busy && !noGas

  if (acc.party.balance === 0n) {
    return (
      <div className="gate-foot callout">
        You hold no tokens yet.{' '}
        <button className="link-button" onClick={onDesk}>
          Get test tokens from the desk
        </button>{' '}
        and come back to send some.
      </div>
    )
  }

  const countAfter = holderCountAfter(model.live.holderCount, acc.party, to, amount)
  const lock = lockupEffect(acc.party, to, amount)
  const dps = model.live.dividendsPerShare

  return (
    <div className="gate-send">
      {result.ok === true && amount > 0n ? (
        <dl className="rows">
          <div className="row">
            <dt>Your tokens</dt>
            <dd>
              <span className="faint">{formatTokens(acc.party.balance)}</span>
              <span className="arrow">to</span>
              {formatTokens(self ? acc.party.balance : acc.party.balance - amount)}
            </dd>
          </div>
          {!self ? (
            <div className="row">
              <dt>Recipient's tokens</dt>
              <dd>
                <span className="faint">{formatTokens(to.balance)}</span>
                <span className="arrow">to</span>
                {formatTokens(to.balance + amount)}
              </dd>
            </div>
          ) : null}
          <div className="row">
            <dt>Holders</dt>
            <dd>
              <span className="faint">{model.live.holderCount.toString()}</span>
              <span className="arrow">to</span>
              {countAfter.toString()}
            </dd>
          </div>
          {lock.recipientStarts || lock.senderCleared ? (
            <div className="row">
              <dt>Lockup clocks</dt>
              <dd style={{ fontWeight: 400 }}>
                {[
                  lock.recipientStarts ? "the recipient's starts when the transfer lands" : null,
                  lock.senderCleared ? 'yours is cleared, since you exit to zero' : null,
                ]
                  .filter(Boolean)
                  .join('; ')}
              </dd>
            </div>
          ) : null}
          <div className="row">
            <dt>Your unclaimed income</dt>
            <dd>
              <span className="faint">{formatEurc(acc.party.claimable)}</span>
              <span className="arrow">to</span>
              {formatEurc(acc.party.claimable)} EURC
            </dd>
          </div>
        </dl>
      ) : null}
      {result.ok === true && amount > 0n && dps > 0n ? (
        <p className="hint">
          Income stays with the seller. The distributor moves equal and opposite corrections between the two wallets, so
          what you have accrued stays yours and the recipient earns from the next coupon.
        </p>
      ) : null}
      {noGas ? (
        <div className="callout" data-tone="warn">
          Your wallet has no {chain.name} ETH for gas. Get some from a{' '}
          <a href={links.ethFaucet} target="_blank" rel="noreferrer">
            faucet
          </a>
          .
        </div>
      ) : null}
      <button
        className="btn btn-primary btn-block"
        disabled={!canSend}
        onClick={() =>
          run('Send tokens', 'Tokens sent', {
            address: d.token,
            abi: tokenAbi,
            functionName: 'transfer',
            args: [to.address, amount],
          })
        }
      >
        {busy ?? (result.ok === true ? `Send ${formatTokenCount(amount)}` : 'The gate stops this transfer')}
      </button>
      <Calls call={`SecurityToken.transfer(${shortAddress(to.address)}, ${solidityAmount(amount, TOKEN_DECIMALS)})`} />
    </div>
  )
}
