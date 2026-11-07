const path = require('path')
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config')

const root = path.resolve(__dirname, '..')
const shared = ['react', 'react-native', 'react-native-nitro-modules']
const escape = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

module.exports = mergeConfig(getDefaultConfig(__dirname), {
  watchFolders: [root],
  resolver: {
    blockList: shared.map(
      (name) => new RegExp(`^${escape(path.join(root, 'node_modules', name))}\\/.*$`)
    ),
    extraNodeModules: Object.fromEntries(
      shared.map((name) => [name, path.join(__dirname, 'node_modules', name)])
    ),
  },
})
