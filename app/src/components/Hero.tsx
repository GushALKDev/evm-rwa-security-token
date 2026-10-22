import { chain } from '../config/chain'
import { formatDuration, formatEurc, formatTokens } from '../lib/format'
import type { TokenModel } from '../lib/model'
import { Gate } from './Gate'

function Figures({ model }: { model: TokenModel }) {
  const live = model.live
  return (
    <div className="figures">
      <div className="figure">
        <div className="figure-value tone-accent">
          {live.holderCount.toString()} <span className="figure-of">of {live.maxHolders.toString()}</span>
        </div>
        <div className="figure-label">Holders, against the cap</div>
      </div>
      <div className="figure">
        <div className="figure-value">{formatTokens(live.totalSupply)}</div>
        <div className="figure-label">Tokens outstanding</div>
      </div>
      <div className="figure">
        <div className="figure-value">{formatDuration(Number(live.lockupPeriod))}</div>
        <div className="figure-label">Lockup from first acquisition</div>
      </div>
      <div className="figure">
        <div className="figure-value">{formatEurc(model.static.couponPerToken)}</div>
        <div className="figure-label">EURC per token, each coupon</div>
      </div>
    </div>
  )
}

export function Hero({ model, onConnect, onDesk }: { model: TokenModel; onConnect: () => void; onDesk: () => void }) {
  return (
    <section className="hero">
      <div className="wrap">
        <div className="hero-head">
          <h1>Every transfer has to clear the gate.</h1>
          <p className="hero-sub">
            A permissioned security token for a real-estate-backed note, running on {chain.name} with testnet tokens.
            Before any token moves, the contract checks who receives it, who sends it and every compliance rule, in a
            fixed order, and stops at the first that fails. Pick two wallets to see where.
          </p>
        </div>
        <Gate model={model} onConnect={onConnect} onDesk={onDesk} />
        <Figures model={model} />
      </div>
    </section>
  )
}
