import { erc20Abi, type Abi } from 'viem'
import {
  complianceAbi,
  countryRestrictionAbi,
  deskAbi,
  distributorAbi,
  documentRegistryAbi,
  eurcAbi,
  identityRegistryAbi,
  lockupAbi,
  maxHoldersAbi,
  securityTokenAbi,
} from '../abi'

type ErrorItem = { type: 'error'; name: string; inputs: readonly { type: string }[] }

const signature = (e: ErrorItem) => `${e.name}(${e.inputs.map((i) => i.type).join(',')})`

/**
 * Every custom error any contract of the deployment can raise, once each. A call into the token can revert in the
 * registry, the engine or a module; a desk call can revert in all of those plus the distributor and the currency.
 * Appending this list to the ABI of the contract called lets viem decode any revert of the call by name.
 */
export const allErrors = (() => {
  const seen = new Map<string, ErrorItem>()
  for (const abi of [
    securityTokenAbi,
    identityRegistryAbi,
    complianceAbi,
    maxHoldersAbi,
    countryRestrictionAbi,
    lockupAbi,
    distributorAbi,
    documentRegistryAbi,
    deskAbi,
    eurcAbi,
  ] as readonly Abi[]) {
    for (const item of abi) {
      if (item.type !== 'error') continue
      const e = item as unknown as ErrorItem
      // The token and the identity registry declare their own errors in their ABIs; keep the first copy.
      if (!seen.has(signature(e))) seen.set(signature(e), e)
    }
  }
  return [...seen.values()]
})()

const withErrors = <T extends Abi>(abi: T) => {
  const own = new Set(abi.filter((i) => i.type === 'error').map((i) => signature(i as unknown as ErrorItem)))
  return [...abi, ...allErrors.filter((e) => !own.has(signature(e)))] as unknown as T
}

export const tokenAbi = withErrors(securityTokenAbi)
export const registryAbi = withErrors(identityRegistryAbi)
export const deskCallAbi = withErrors(deskAbi)
export const distributorCallAbi = withErrors(distributorAbi)
export const currencyAbi = withErrors([...erc20Abi, ...eurcAbi.filter((i) => i.type === 'error')] as Abi)

export {
  complianceAbi,
  countryRestrictionAbi,
  deskAbi,
  distributorAbi,
  documentRegistryAbi,
  identityRegistryAbi,
  lockupAbi,
  maxHoldersAbi,
  securityTokenAbi,
}
