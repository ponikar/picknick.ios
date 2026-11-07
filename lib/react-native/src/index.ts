import { NitroModules } from 'react-native-nitro-modules'
import type { Picknick as PicknickSpec } from './specs/Picknick.nitro'

export type {
  IndexStatus,
  MatchSignal,
  PhotoAccess,
  PicknickConfig,
  SearchHit,
  SearchOptions,
} from './specs/Picknick.nitro'

export const Picknick = NitroModules.createHybridObject<PicknickSpec>('Picknick')
