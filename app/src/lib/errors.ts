import {
  BaseError,
  ChainMismatchError,
  ContractFunctionRevertedError,
  InsufficientFundsError,
  UserRejectedRequestError,
} from 'viem'
import { chain } from '../config/chain'
import { formatNotes, formatTimestamp } from './format'

export interface ErrorContext {
  /** Names an address for the sentence: "your wallet", a seeded wallet's label, or a short address */
  labelOf: (address: string) => string
  /**
   * ComplianceCheckFailed does not say which module rejected the transfer. The caller can name it from the
   * gate it evaluated for the same call.
   */
  rejectingRule?: string
}

/** The call passed simulation but reverted once mined, so nothing changed. */
export const LANDED_REVERT =
  'The transaction reverted when it landed, so nothing changed. The state moved between the check and the block: try again.'

/**
 * Turns a failed simulation or transaction into one sentence that says what happened and, where it helps, what
 * to do. Contract errors are decoded by name from the combined ABI (lib/abi.ts), whichever contract raised them.
 */
export function describeError(err: unknown, ctx: ErrorContext): string {
  if (err instanceof Error && err.message === LANDED_REVERT) return err.message
  // A write names the app's chain (lib/tx.ts), so viem, or wagmi before it, refuses when the wallet is elsewhere.
  const chainMismatch = (e: unknown) =>
    e instanceof ChainMismatchError || (e as Error | undefined)?.name === 'ConnectorChainMismatchError'
  if (chainMismatch(err) || (err instanceof BaseError && err.walk(chainMismatch)))
    return `Your wallet is on another network. Switch it to ${chain.name} and try again.`
  if (!(err instanceof BaseError)) return err instanceof Error ? err.message : 'The request failed.'

  if (err.walk((e) => e instanceof UserRejectedRequestError)) return 'You rejected the request in your wallet.'
  if (err.walk((e) => e instanceof InsufficientFundsError))
    return `Your wallet needs ${chain.name} ETH to pay for gas. Get some from a faucet and try again.`

  const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null
  const name = reverted?.data?.errorName
  const a = (reverted?.data?.args ?? []) as readonly unknown[]
  const who = (x: unknown) => ctx.labelOf(x as string)
  const at = (x: unknown) => formatTimestamp(x as bigint)

  switch (name) {
    // The transfer gate (SecurityToken)
    case 'EnforcedPause':
      return 'The agent has paused the token, so no notes can be sent until it is unpaused.'
    case 'RecipientNotVerified':
      return `${capital(who(a[0]))} is not a verified investor, so it cannot receive notes.`
    case 'SenderNotVerified':
      return `${capital(who(a[0]))} is not verified (its identity was removed or its KYC lapsed), so its notes cannot be sent.`
    case 'RecipientAddressFrozen':
      return `${capital(who(a[0]))} is frozen, so transfers to it are refused.`
    case 'SenderAddressFrozen':
      return `${capital(who(a[0]))} is frozen, so its notes cannot be sent.`
    case 'InsufficientUnfrozenBalance':
      return `Only ${formatNotes(a[1] as bigint)} notes of ${who(a[0])} are free to move, less than the ${formatNotes(a[2] as bigint)} requested.`
    case 'ComplianceCheckFailed': {
      // A zero sender is a mint: the desk's issue runs the same rules as a transfer.
      const what = (a[0] as string)?.toLowerCase() === '0x0000000000000000000000000000000000000000' ? 'the issue' : 'the transfer'
      return ctx.rejectingRule
        ? `A compliance rule rejected ${what}: ${ctx.rejectingRule}`
        : `A compliance rule rejected ${what}.`
    }
    case 'ERC20InsufficientBalance':
      return 'The balance is too low for this amount.'
    case 'ERC20InvalidReceiver':
      return 'Notes cannot be sent to the zero address.'
    // The testnet desk
    case 'InvalidCountry':
      return 'Choose a country: the code must be between 1 and 999.'
    case 'ClaimTooSoon':
      return `The desk issues notes to each wallet once a day. Yours opens again on ${at(a[1])}.`
    case 'CouponTooSoon':
      return `A coupon was paid less than ten minutes ago. The next one can be paid from ${at(a[0])}.`
    case 'DistributorNotSet':
      return 'The desk has no distributor wired yet, so it cannot pay coupons.'
    // The dividend distributor
    case 'NothingToClaim':
      return 'Nothing to claim yet. Income accrues to the notes you hold when a coupon is paid.'
    case 'ClaimantFrozen':
      return 'Your wallet is frozen, so the distributor withholds its income until the freeze is lifted.'
    case 'ClaimantNotVerified':
      return 'Your wallet is not verified, so the distributor withholds its income. Onboard again to release it.'
    case 'ZeroDeposit':
      return 'At the current supply the coupon would be zero.'
    case 'NoSupply':
      return 'No notes are outstanding, so a coupon would accrue to nobody.'
    case 'DistributorNotAttached':
      return 'The distributor has been removed from the compliance engine, so it accepts no new coupons.'
    // Roles and the rest
    case 'AccessControlUnauthorizedAccount':
      return 'This account does not hold the role this action needs.'
    case 'OwnableUnauthorizedAccount':
      return 'Only the desk owner can do this.'
    case 'OnlyMinter':
      return 'Only the desk can mint the testnet EURC.'
    case 'AttestationExpired':
      return 'The attestation would already be expired when written.'
    case 'ZeroAddress':
      return 'The zero address is not accepted here.'
  }

  if (reverted) return `The transaction would revert${name ? ` (${name})` : ''}.`
  return err.shortMessage || 'The request failed.'
}

function capital(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1)
}
