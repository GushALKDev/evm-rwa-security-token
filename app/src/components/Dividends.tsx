import { useConnection } from 'wagmi'
import { chain, explorerAddress, links } from '../config/chain'
import { useCorrection } from '../hooks/useTokenData'
import { useTx } from '../hooks/useTx'
import { deskCallAbi, distributorCallAbi } from '../lib/abi'
import { accumulated, couponAmount, depositEffect, perNote } from '../lib/dividends'
import { formatDuration, formatEurc, formatNoteCount, formatTimestamp } from '../lib/format'
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
  const correction = useCorrection(acc?.address, `${live.dividendsPerShare}-${acc?.party.balance}`)

  const amount = couponAmount(live.totalSupply, st.couponPerNote)
  const open = model.chainTime >= live.nextCouponAt
  const wait = Number(live.nextCouponAt - model.now)
  const after = live.totalSupply > 0n && amount > 0n ? depositEffect(live.dividendsPerShare, live.residue, live.totalSupply, amount) : null
  const bal = acc?.party.balance ?? 0n
  const share =
    after && acc && correction.data !== undefined && bal > 0n
      ? accumulated(bal, after.dividendsPerShare, correction.data) - accumulated(bal, live.dividendsPerShare, correction.data)
      : null
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
          <div className="figure-value tone-accent">{formatEurc(perNote(live.dividendsPerShare))}</div>
          <div className="figure-label">EURC paid per note since issuance</div>
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

      <div className="coupon-action">
        <dl className="rows">
          <div className="row">
            <dt>Deposits</dt>
            <dd>
              {formatEurc(amount)} EURC <span className="faint">{formatEurc(st.couponPerNote)} for each of {formatNoteCount(live.totalSupply)}</span>
            </dd>
          </div>
          {after ? (
            <div className="row">
              <dt>Paid per note since issuance</dt>
              <dd>
                <span className="faint">{formatEurc(perNote(live.dividendsPerShare))}</span>
                <span className="arrow">to</span>
                {formatEurc(perNote(after.dividendsPerShare))} EURC
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
          The testnet desk stands in for the paying agent: it mints {formatEurc(st.couponPerNote)} testnet EURC per note
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

function IncomeCard({ model }: { model: TokenModel }) {
  const { chainId } = useConnection()
  const wrongChain = chainId !== chain.id
  const acc = model.account!
  const p = acc.party
  const d = model.deployment
  const { run, busy } = useTx({ labelOf: (a) => labelOf(d, acc.address, a) })
  const correction = useCorrection(acc.address, `${model.live.dividendsPerShare}-${p.balance}`)
  const why = identityWhy(p, model.chainTime)
  const withheld = p.frozen ? 'frozen' : why !== 'verified' ? 'unverified' : null
  const noGas = acc.extras?.eth === 0n
  const total = p.claimable + p.withdrawn

  return (
    <div className="card">
      <div className="card-title">
        <h3>Your income</h3>
      </div>
      <div className="position-main">
        <span className="position-state">Ready to claim</span>
        <span className="position-amount">
          {formatEurc(p.claimable)}
          <small>EURC</small>
        </span>
        <span className="hint">
          {p.balance > 0n
            ? `Accrues to your ${formatNoteCount(p.balance)} with every coupon paid while you hold them.`
            : 'Hold notes when a coupon is paid to earn a share of it.'}
        </span>
      </div>
      <dl className="rows">
        <div className="row">
          <dt>Earned since you first held notes</dt>
          <dd>{formatEurc(total)} EURC</dd>
        </div>
        <div className="row">
          <dt>Claimed so far</dt>
          <dd>{formatEurc(p.withdrawn)} EURC</dd>
        </div>
        <div className="row">
          <dt>In your wallet</dt>
          <dd>{formatEurc(acc.extras?.eurc ?? 0n)} EURC</dd>
        </div>
      </dl>
      {wrongChain ? (
        <div className="callout" data-tone="warn" style={{ marginTop: 14 }}>
          Your wallet is on another network. Switch to {chain.name} from the button at the top first.
        </div>
      ) : null}
      {withheld ? (
        <div className="callout" data-tone="warn" style={{ marginTop: 14 }}>
          {withheld === 'frozen'
            ? 'Your wallet is frozen, so the distributor withholds its income. It keeps accruing and is released when the freeze is lifted.'
            : 'Your wallet is not verified, so the distributor withholds its income. It keeps accruing; verify again at the desk to release it.'}
        </div>
      ) : null}
      <button
        className="btn btn-primary btn-block"
        style={{ marginTop: 16 }}
        disabled={p.claimable === 0n || !!withheld || !!busy || noGas || wrongChain}
        onClick={() =>
          run(`Claim ${formatEurc(p.claimable)} EURC`, 'Income claimed', {
            address: d.distributor,
            abi: distributorCallAbi,
            functionName: 'claim',
            args: [acc.address],
          })
        }
      >
        {busy ?? (p.claimable > 0n ? `Claim ${formatEurc(p.claimable)} EURC` : 'Nothing to claim yet')}
      </button>
      {correction.data !== undefined ? (
        <details className="formula">
          <summary>How this figure is computed</summary>
          <p>
            Earned = ⌊(notes × dividends per share − correction) / 2<sup>128</sup>⌋, with the contract's own values for
            your wallet. The floor rounds each wallet's figure down, never up, which keeps the distributor able to pay every
            claim.
          </p>
          <dl className="rows mono-rows">
            <div className="row">
              <dt>notes (base units)</dt>
              <dd className="mono">{p.balance.toString()}</dd>
            </div>
            <div className="row">
              <dt>dividends per share</dt>
              <dd className="mono">{model.live.dividendsPerShare.toString()}</dd>
            </div>
            <div className="row">
              <dt>correction</dt>
              <dd className="mono">{correction.data.toString()}</dd>
            </div>
            <div className="row">
              <dt>earned (EURC units)</dt>
              <dd className="mono">{accumulated(p.balance, model.live.dividendsPerShare, correction.data).toString()}</dd>
            </div>
          </dl>
        </details>
      ) : null}
    </div>
  )
}

export function DividendsPage({ model, onConnect }: { model: TokenModel; onConnect: () => void }) {
  const { status } = useConnection()
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
            {status === 'connected' && model.account ? (
              <IncomeCard model={model} />
            ) : (
              <div className="card">
                <div className="card-title">
                  <h3>Your income</h3>
                </div>
                <p className="muted">Connect a wallet to see what your notes have earned and claim it.</p>
              </div>
            )}
          </div>
        </div>
      </div>
    </section>
  )
}
