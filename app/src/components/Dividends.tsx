import { useState } from 'react'
import { useConnection } from 'wagmi'
import { chain, explorerAddress, links } from '../config/chain'
import type { SeedKey } from '../config/deployment'
import { useAccumulator } from '../hooks/useTokenData'
import { useTx } from '../hooks/useTx'
import { deskCallAbi, distributorCallAbi } from '../lib/abi'
import { accumulated, couponAmount, couponPreview, depositEffect, MAGNITUDE, ONE_TOKEN, perToken } from '../lib/dividends'
import { formatDuration, formatEurc, formatTokenCount, formatTimestamp } from '../lib/format'
import { identityWhy } from '../lib/gate'
import { labelOf, type TokenModel } from '../lib/model'

function CouponCard({ model, onConnect }: { model: TokenModel; onConnect: () => void }) {
  const { status, chainId } = useConnection()
  const wrongChain = status === 'connected' && chainId !== chain.id
  const live = model.live
  const st = model.static
  const d = model.deployment
  const acc = model.account
  const { run, busy } = useTx({ labelOf: (a) => labelOf(d, acc?.address, a) })
  const snapshot = useAccumulator(acc?.address)

  const amount = couponAmount(live.totalSupply, st.couponPerToken)
  const open = model.chainTime >= live.nextCouponAt
  const wait = Number(live.nextCouponAt - model.now)
  const after = live.totalSupply > 0n && amount > 0n ? depositEffect(live.dividendsPerShare, live.residue, live.totalSupply, amount) : null
  // The share comes from one snapshot of the account's inputs, read at a single block.
  const preview = snapshot.data && snapshot.data.balance > 0n ? couponPreview(snapshot.data, st.couponPerToken) : null
  const share = preview?.share ?? null
  const noGas = acc?.extras?.eth === 0n

  return (
    <div className="sheet">
      <div className="sheet-top">
        <h2>Coupons</h2>
        <a className="card-sub" href={explorerAddress(d.distributor)} target="_blank" rel="noreferrer">
          Read live from {chain.name}
        </a>
      </div>
      <div className="figures figures-flush">
        <div className="figure">
          <div className="figure-value tone-accent">{formatEurc(perToken(live.dividendsPerShare))}</div>
          <div className="figure-label">EURC paid per token since issuance</div>
        </div>
        <div className="figure">
          <div className="figure-value">{formatEurc(live.distributorHeld)}</div>
          <div className="figure-label">EURC held for holders, unclaimed</div>
        </div>
        <div className="figure">
          <div className="figure-value">{formatEurc(amount)}</div>
          <div className="figure-label">EURC in the next coupon, at today's supply</div>
        </div>
        <div className="figure">
          <div className="figure-value">{open ? 'Open' : formatDuration(Math.max(wait, 0))}</div>
          <div className="figure-label">{open ? 'Anyone can pay the next coupon' : 'Until the next coupon opens'}</div>
        </div>
      </div>
      {(live.dividendsPerShare * ONE_TOKEN) % MAGNITUDE !== 0n ? (
        <p className="hint figures-note">
          Figures round down, as the contract does. It rounds the running total down at every coupon and carries the
          remainder into the next, so {formatEurc(st.couponPerToken)} EURC a token can read{' '}
          {formatEurc(st.couponPerToken - 1n)}. Each wallet's income is rounded down too, never up, which keeps the
          distributor able to pay every claim.
        </p>
      ) : null}

      <div className="coupon-action">
        <dl className="rows">
          <div className="row">
            <dt>Deposits</dt>
            <dd>
              {formatEurc(amount)} EURC <span className="faint">{formatEurc(st.couponPerToken)} for each of {formatTokenCount(live.totalSupply)}</span>
            </dd>
          </div>
          {after ? (
            <div className="row">
              <dt>Paid per token since issuance</dt>
              <dd>
                <span className="faint">{formatEurc(perToken(live.dividendsPerShare))}</span>
                <span className="arrow">to</span>
                {formatEurc(perToken(after.dividendsPerShare))} EURC
              </dd>
            </div>
          ) : null}
          {share !== null ? (
            <div className="row">
              <dt>Your share</dt>
              <dd>+{formatEurc(share)} EURC</dd>
            </div>
          ) : null}
        </dl>
        <p className="hint">
          The testnet desk stands in for the paying agent: it mints {formatEurc(st.couponPerToken)} testnet EURC per token
          outstanding and deposits it, at most once every {formatDuration(Number(st.couponInterval))}, whoever asks.
          {open ? null : ` The next one opens on ${formatTimestamp(live.nextCouponAt)}.`}
        </p>
        {status !== 'connected' ? (
          <button className="btn btn-block" onClick={onConnect}>
            Connect a wallet to pay a coupon
          </button>
        ) : (
          <button
            className="btn btn-primary btn-block"
            disabled={!open || !!busy || noGas || wrongChain || amount === 0n}
            onClick={() =>
              run('Pay the coupon', 'Coupon paid', { address: d.desk, abi: deskCallAbi, functionName: 'payCoupon' })
            }
          >
            {busy ?? (open ? `Pay ${formatEurc(amount)} EURC to holders` : 'The next coupon is not open yet')}
          </button>
        )}
        {wrongChain ? (
          <p className="hint" data-tone="warn">
            Your wallet is on another network. Switch to {chain.name} from the button at the top first.
          </p>
        ) : null}
        {noGas ? (
          <p className="hint" data-tone="warn">
            Your wallet has no {chain.name} ETH for gas. Get some from a{' '}
            <a href={links.ethFaucet} target="_blank" rel="noreferrer">
              faucet
            </a>
            .
          </p>
        ) : null}
      </div>
    </div>
  )
}

type Subject = 'you' | SeedKey

/** Income of the visitor's wallet or of any seeded one: the same figures and formula, and a claim for your own. */
function IncomeCard({ model, onConnect }: { model: TokenModel; onConnect: () => void }) {
  const { status, chainId } = useConnection()
  const d = model.deployment
  const acc = model.account
  const connected = status === 'connected' && !!acc
  const wrongChain = chainId !== chain.id
  // Null means "the default": your wallet when one is connected, the settled holder otherwise.
  const [pick, setPick] = useState<Subject | null>(null)
  const subject: Subject = pick && (pick !== 'you' || connected) ? pick : connected ? 'you' : 'settled'
  const you = subject === 'you'
  const address = you ? acc!.address : d.seeds.find((s) => s.key === subject)!.address
  const p = you ? acc!.party : model.parties.get(address.toLowerCase())
  const { run, busy } = useTx({ labelOf: (a) => labelOf(d, acc?.address, a) })
  const snapshot = useAccumulator(address)
  const s = snapshot.data
  const earned = s && s.balance * s.dividendsPerShare >= s.correction ? accumulated(s.balance, s.dividendsPerShare, s.correction) : null

  if (!p) return null
  const why = identityWhy(p, model.chainTime)
  const withheld = p.frozen ? 'frozen' : why !== 'verified' ? 'unverified' : null
  const noGas = acc?.extras?.eth === 0n
  const total = p.claimable + p.withdrawn
  const whose = you ? 'Your wallet' : 'This wallet'

  return (
    <div className="card">
      <div className="card-title">
        <h3>Income</h3>
      </div>
      <div className="field income-pick">
        <label className="field-label" htmlFor="income-wallet">
          <span>Wallet</span>
        </label>
        <select id="income-wallet" className="select" value={subject} onChange={(e) => setPick(e.target.value as Subject)}>
          {connected ? <option value="you">Your wallet</option> : null}
          <optgroup label="Seeded wallets">
            {d.seeds.map((seed) => (
              <option key={seed.key} value={seed.key}>
                {seed.label}
              </option>
            ))}
          </optgroup>
        </select>
      </div>
      <div className="position-main">
        <span className="position-state">{you ? 'Ready to claim' : 'Unclaimed'}</span>
        <span className="position-amount">
          {formatEurc(p.claimable)}
          <small>EURC</small>
        </span>
        <span className="hint">
          {p.balance === 0n
            ? you
              ? 'Hold tokens when a coupon is paid to earn a share of it.'
              : 'It holds no tokens, so coupons pay it nothing.'
            : you
              ? `Accrues to your ${formatTokenCount(p.balance)} with every coupon paid while you hold them.`
              : `Accrues to its ${formatTokenCount(p.balance)} with every coupon. Nobody can sign for a seeded wallet, so it never claims and its income keeps growing.`}
        </span>
      </div>
      <dl className="rows">
        <div className="row">
          <dt>Earned since first holding tokens</dt>
          <dd>{formatEurc(total)} EURC</dd>
        </div>
        <div className="row">
          <dt>Claimed so far</dt>
          <dd>{formatEurc(p.withdrawn)} EURC</dd>
        </div>
        {you ? (
          <div className="row">
            <dt>In your wallet</dt>
            <dd>{formatEurc(acc!.extras?.eurc ?? 0n)} EURC</dd>
          </div>
        ) : null}
      </dl>
      {you && wrongChain ? (
        <div className="callout" data-tone="warn" style={{ marginTop: 14 }}>
          Your wallet is on another network. Switch to {chain.name} from the button at the top first.
        </div>
      ) : null}
      {withheld ? (
        <div className="callout" data-tone="warn" style={{ marginTop: 14 }}>
          {withheld === 'frozen'
            ? `${whose} is frozen, so the distributor withholds its income. It keeps accruing and is released when the freeze is lifted.`
            : you
              ? 'Your wallet is not verified, so the distributor withholds its income. It keeps accruing; verify again at the desk to release it.'
              : 'This wallet is not verified, so the distributor withholds its income. It keeps accruing and is released if the agent verifies it again.'}
        </div>
      ) : null}
      {you ? (
        <>
          <button
            className="btn btn-primary btn-block"
            style={{ marginTop: 16 }}
            disabled={p.claimable === 0n || !!withheld || !!busy || noGas || wrongChain}
            onClick={() =>
              run(`Claim ${formatEurc(p.claimable)} EURC`, 'Income claimed', {
                address: d.distributor,
                abi: distributorCallAbi,
                functionName: 'claim',
                args: [address],
              })
            }
          >
            {busy ?? (p.claimable > 0n ? `Claim ${formatEurc(p.claimable)} EURC` : 'Nothing to claim yet')}
          </button>
        </>
      ) : !connected && status !== 'connected' ? (
        <p className="hint" style={{ marginTop: 14 }}>
          To earn and claim income of your own,{' '}
          <button className="link-button" onClick={onConnect}>
            connect a wallet
          </button>{' '}
          and get test tokens from the desk.
        </p>
      ) : null}
      {s && earned !== null ? (
        <details className="formula" open>
          <summary>How this figure is computed</summary>
          <p>
            Earned = ⌊(tokens × dividends per share − correction) / 2<sup>128</sup>⌋, with the contract's own values for
            this wallet, all read at block {s.blockNumber.toString()}. Every transfer and mint shifts the correction, so tokens
            received after a coupon earn nothing from it. The floor rounds each wallet's figure down, never up, which keeps
            the distributor able to pay every claim.
          </p>
          <dl className="rows mono-rows">
            <div className="row">
              <dt>tokens (base units)</dt>
              <dd className="mono">{s.balance.toString()}</dd>
            </div>
            <div className="row">
              <dt>dividends per share</dt>
              <dd className="mono">{s.dividendsPerShare.toString()}</dd>
            </div>
            <div className="row">
              <dt>correction</dt>
              <dd className="mono">{s.correction.toString()}</dd>
            </div>
            <div className="row">
              <dt>earned (EURC units)</dt>
              <dd className="mono">{earned.toString()}</dd>
            </div>
          </dl>
        </details>
      ) : null}
    </div>
  )
}

export function DividendsPage({ model, onConnect }: { model: TokenModel; onConnect: () => void }) {
  return (
    <section className="section">
      <div className="wrap">
        <div className="section-head">
          <h2>Income, without walking the holder list</h2>
          <p>
            A coupon raises one running total, dividends per share. A wallet's income is its balance times that total, less
            a correction the distributor shifts on every transfer, so paying a coupon costs the same for five holders or
            five thousand, and a sale never moves income already earned.
          </p>
        </div>
        <div className="main-grid">
          <div className="stack">
            <CouponCard model={model} onConnect={onConnect} />
          </div>
          <div className="stack">
            <IncomeCard model={model} onConnect={onConnect} />
          </div>
        </div>
      </div>
    </section>
  )
}
