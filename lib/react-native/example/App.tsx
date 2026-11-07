import { useCallback, useEffect, useState } from 'react'
import {
  Button,
  FlatList,
  Image,
  StyleSheet,
  Text,
  TextInput,
  View,
  useWindowDimensions,
} from 'react-native'
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context'
import { Picknick, type IndexStatus, type PicknickConfig, type SearchHit } from 'react-native-picknick'

const config: PicknickConfig = {
  imageModel: 'mobileclip_s2_image.mlmodelc',
  textModel: 'mobileclip_s2_text.mlmodelc',
  merges: 'bpe_merges.txt',
  cities: 'cities15000.txt',
  countryInfo: 'countryInfo.txt',
  admin1Codes: 'admin1CodesASCII.txt',
}

const columns = 3

async function prepare(onProgress: (status: IndexStatus) => void): Promise<IndexStatus> {
  await Picknick.configure(config)
  const access = await Picknick.requestPhotoAccess()
  if (access !== 'authorized' && access !== 'limited') {
    throw new Error(`photo access ${access}`)
  }
  return Picknick.indexLibrary(onProgress)
}

function check(condition: boolean, reason: string): void {
  if (!condition) throw new Error(reason)
}

async function selfTest(onProgress: (status: IndexStatus) => void): Promise<SearchHit[]> {
  const status = await prepare(onProgress)
  check(status.searchable > 0, `nothing searchable (total ${status.total})`)

  const dog = await Picknick.search('a dog')
  check(dog.length > 0, "search('a dog') returned no hits")
  check(
    dog.every((hit, i) => i === 0 || dog[i - 1]!.probability >= hit.probability),
    "search('a dog') not sorted by probability desc"
  )
  check(
    dog.every((hit) => hit.probability >= 0 && hit.probability <= 1),
    "search('a dog') probability outside 0..1"
  )

  const top = await Picknick.search('a dog', { topN: 3 })
  check(top.length <= 3, `topN 3 returned ${top.length}`)

  const confident = await Picknick.search('a dog', { minimumProbability: 0.99 })
  check(
    confident.every((hit) => hit.probability >= 0.99),
    'minimumProbability 0.99 returned a hit below 0.99'
  )

  const vietnam = await Picknick.search('vietnam')
  check(vietnam.length === 0, `search('vietnam') returned ${vietnam.length}`)
  return dog
}

function runSelfTest(onProgress: (status: IndexStatus) => void, onHits: (hits: SearchHit[]) => void): void {
  selfTest(onProgress).then(
    (hits) => {
      onHits(hits)
      console.log('PICKNICK_SELFTEST PASS')
    },
    (error: unknown) =>
      console.log(`PICKNICK_SELFTEST FAIL ${error instanceof Error ? error.message : String(error)}`)
  )
}

function SearchScreen({ selfTestOnLaunch }: { selfTestOnLaunch: boolean }) {
  const { width } = useWindowDimensions()
  const [status, setStatus] = useState<IndexStatus>()
  const [error, setError] = useState<string>()
  const [query, setQuery] = useState('')
  const [topN, setTopN] = useState('50')
  const [minimumProbability, setMinimumProbability] = useState('0')
  const [hits, setHits] = useState<SearchHit[]>([])

  useEffect(() => {
    if (selfTestOnLaunch) {
      runSelfTest(setStatus, setHits)
      return
    }
    prepare(setStatus).then(setStatus, (e: unknown) => setError(String(e)))
  }, [selfTestOnLaunch])

  const search = useCallback(() => {
    Picknick.search(query, {
      topN: Number(topN) || undefined,
      minimumProbability: Number(minimumProbability) || undefined,
    }).then(setHits, (e: unknown) => setError(String(e)))
  }, [query, topN, minimumProbability])

  const size = width / columns

  return (
    <SafeAreaView style={styles.screen}>
      <TextInput
        style={styles.input}
        placeholder="Search photos"
        value={query}
        onChangeText={setQuery}
        onSubmitEditing={search}
        returnKeyType="search"
        autoCorrect={false}
      />
      <View style={styles.row}>
        <Text>Top N</Text>
        <TextInput style={styles.small} value={topN} onChangeText={setTopN} keyboardType="number-pad" />
        <Text>Min p</Text>
        <TextInput
          style={styles.small}
          value={minimumProbability}
          onChangeText={setMinimumProbability}
          keyboardType="decimal-pad"
        />
        <Button title="Search" onPress={search} />
        <Button title="Self-test" onPress={() => runSelfTest(setStatus, setHits)} />
      </View>
      <Text style={styles.status}>
        {error ??
          (status
            ? `${status.searchable}/${status.total} searchable${status.isIndexing ? ', indexing…' : ''} · ${hits.length} hits`
            : 'Preparing…')}
      </Text>
      <FlatList
        data={hits}
        numColumns={columns}
        keyExtractor={(hit) => hit.id}
        renderItem={({ item }) => (
          <View style={{ width: size, height: size }}>
            <Image source={{ uri: item.uri }} style={styles.image} />
            <Text style={styles.probability}>{item.probability.toFixed(2)}</Text>
          </View>
        )}
      />
    </SafeAreaView>
  )
}

export default function App({ selfTest: selfTestOnLaunch = false }: { selfTest?: boolean }) {
  return (
    <SafeAreaProvider>
      <SearchScreen selfTestOnLaunch={selfTestOnLaunch} />
    </SafeAreaProvider>
  )
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: 'white' },
  input: { margin: 8, padding: 8, borderWidth: 1, borderColor: '#ccc', borderRadius: 6 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 8 },
  small: { width: 48, padding: 4, borderWidth: 1, borderColor: '#ccc', borderRadius: 4 },
  status: { padding: 8, color: '#555' },
  image: { flex: 1, margin: 1 },
  probability: {
    position: 'absolute',
    right: 4,
    bottom: 4,
    color: 'white',
    backgroundColor: 'rgba(0,0,0,0.6)',
    paddingHorizontal: 4,
    fontSize: 11,
  },
})
