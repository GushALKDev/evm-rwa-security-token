import { useConnection } from 'wagmi'
import { chain, links } from '../config/chain'
import { navigate } from '../hooks/useRoute'
import { countryLabel } from '../lib/countries'
import { formatDate, formatDuration, formatEurc, formatNoteCount, formatNotes, formatTimestamp, shortAddress } from '../lib/format'
import { identityWhy, senderBlock } from '../lib/gate'
import type { AccountView, TokenModel } from '../lib/model'
import { Link } from './Sections'

function GetStarted({ model }: { model: TokenModel }) {
  return (
    <div className="card">
      <div className="card-title">
        <h3>Hold and send a note in a few minutes</h3>
      </div>
      <div className="flow">
        <div className="flow-step">
          <b>1</b>
          <span>
            Get a little {chain.name} ETH for gas from a{' '}
            <a href={links.ethFaucet} target="_blank" rel="noreferrer">
              faucet
            </a>
            .
          </span>
        </div>
        <div className="flow-step">
          <b>2</b>
          <span>Connect, then verify your wallet at the desk (the Test notes button at the top) and get test notes.</span>
        </div>
        <div className="flow-step">
          <b>3</b>
          <span>
            Wait out the {formatDuration(Number(model.live.lockupPeriod))} lockup, then send notes through the gate, to a
            seeded wallet or to a second wallet of yours.
          </span>
        </div>
        <div className="flow-step">
          <b>4</b>
          <span>
            Pay a coupon and claim your share on the <Link href="/dividends">Dividends</Link> page.
          </span>
        </div>
      </div>
    </div>
  )
}

function Summary({ model, acc }: { model: TokenModel; acc: AccountView }) {
  const p = acc.party
  const why = identityWhy(p, model.chainTime)
  const left = acc.unlocksAt !== null ? Number(acc.unlocksAt - model.now) : 0
  const block = senderBlock(model.gate, p, model.chainTime)
  return (
    <>
      <div className="position-main">
        <span className="position-state">{why === 'verified' ? 'Verified investor' : 'Not verified'}</span>
        <span className="position-amount">
          {formatNotes(p.balance)}
          <small>{model.static.tokenSymbol}</small>
        </span>
        <span className="hint">
          {p.balance === 0n
            ? 'No notes yet.'
            : block === 'paused'
              ? 'The agent has paused the token, so no notes can move.'
              : block === 'unverified'
                ? 'Your wallet is not verified, so its notes cannot move until it is verified again.'
                : block === 'frozen'
                  ? 'The agent froze your wallet, so its notes cannot move.'
                  : block === 'locked'
                    ? `Locked until ${formatTimestamp(acc.unlocksAt!)}${left > 0 ? `, ${formatDuration(left)} from now` : ''}. Your lockup runs from your first notes.`
                    : `${formatNoteCount(acc.free)} free to send.`}
        </span>
      </div>
      <dl className="rows">
        <div className="row">
          <dt>Identity</dt>
          <dd>
            {why === 'verified'
              ? `${countryLabel(p.country)}, until ${formatDate(p.kycExpiry)}`
              : why === 'lapsed'
                ? `KYC lapsed on ${formatDate(p.kycExpiry)}`
                : why === 'removed'
                  ? 'Removed by the agent'
                  : 'Not registered'}
          </dd>
        </div>
        {p.investorId !== '0x0000000000000000000000000000000000000000000000000000000000000000' ? (
          <div className="row">
            <dt>Investor id</dt>
            <dd className="mono">{shortAddress(p.investorId)}</dd>
          </div>
        ) : null}
        {p.frozen || p.frozenTokens > 0n ? (
          <div className="row">
            <dt>Frozen</dt>
            <dd className="tone-danger">{p.frozen ? 'The whole wallet' : formatNoteCount(p.frozenTokens)}</dd>
          </div>
        ) : null}
        <div className="row">
          <dt>Unclaimed income</dt>
          <dd>
            {formatEurc(p.claimable)} EURC{' '}
            {p.claimable > 0n ? (
              <Link className="link-button" style={{ marginLeft: 8, fontSize: 13 }} href="/dividends">
                Claim
              </Link>
            ) : null}
          </dd>
        </div>
      </dl>
    </>
  )
}

export function PositionCard({ model, onConnect, onDesk }: { model: TokenModel; onConnect: () => void; onDesk: () => void }) {
  const { status, chainId } = useConnection()
  const acc = model.account

  if (status !== 'connected') {
    return (
      <>
        <div className="card">
          <div className="card-title">
            <h2>Your position</h2>
          </div>
          <div className="empty">
            <p>
              <strong>Connect a wallet to hold and send notes.</strong> The gate above runs on the seeded wallets without
              one.
            </p>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              <button className="btn btn-primary" onClick={onConnect}>
                Connect wallet
              </button>
              <button className="btn" onClick={onDesk}>
                Get test notes
              </button>
            </div>
          </div>
        </div>
        <GetStarted model={model} />
      </>
    )
  }

  if (chainId !== chain.id) {
    return (
      <div className="card">
        <div className="card-title">
          <h2>Your position</h2>
        </div>
        <p className="muted">Your wallet is on another network. Switch to {chain.name} from the button at the top.</p>
      </div>
    )
  }

  if (!acc) {
    return (
      <div className="card">
        <div className="card-title">
          <h2>Your position</h2>
        </div>
        <p className="muted">Reading your position…</p>
      </div>
    )
  }

  const verified = identityWhy(acc.party, model.chainTime) === 'verified'
  return (
    <>
      <div className="card">
        <div className="card-title">
          <h2>Your position</h2>
          <button className="link-button" onClick={onDesk}>
            {verified ? 'Get test notes' : 'Verify at the desk'}
          </button>
        </div>
        <Summary model={model} acc={acc} />
        {acc.party.balance > 0n ? (
          <button className="btn btn-block" style={{ marginTop: 18 }} onClick={() => navigate('/#gate')}>
            Send notes through the gate
          </button>
        ) : null}
      </div>
      {acc.party.balance === 0n ? <GetStarted model={model} /> : null}
    </>
  )
}
