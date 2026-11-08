import type { HybridObject } from 'react-native-nitro-modules'

export type PhotoAccess = 'authorized' | 'limited' | 'denied' | 'restricted' | 'notDetermined'

export type MatchSignal = 'semantic' | 'label' | 'text' | 'place' | 'person' | 'filter'

export interface PicknickConfig {
  imageModel: string
  textModel: string
  merges: string
  cities?: string
  countryInfo?: string
  admin1Codes?: string
  database?: string
}

export interface IndexStatus {
  total: number
  searchable: number
  isIndexing: boolean
}

export interface SearchOptions {
  topN?: number
  minimumProbability?: number
}

export interface SearchHit {
  id: string
  uri: string
  probability: number
  matchedBy: MatchSignal[]
}

export interface FaceBox {
  x: number
  y: number
  width: number
  height: number
}

export interface FaceRef {
  faceId: string
  photoId: string
  uri: string
  box: FaceBox
}

export interface FaceGroup {
  id: number
  name?: string
  photoCount: number
  faces: FaceRef[]
}

export interface Picknick extends HybridObject<{ ios: 'swift' }> {
  configure(config: PicknickConfig): Promise<void>
  requestPhotoAccess(): Promise<PhotoAccess>
  indexLibrary(onProgress?: (status: IndexStatus) => void): Promise<IndexStatus>
  getStatus(): Promise<IndexStatus>
  search(query: string, options?: SearchOptions): Promise<SearchHit[]>
  faceGroups(): Promise<FaceGroup[]>
  nameFace(faceId: string, name: string): Promise<void>
  unnameFace(faceId: string): Promise<void>
}
