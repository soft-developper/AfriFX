/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  webpack: (config) => {
    config.resolve.fallback = {
      ...config.resolve.fallback,
      // MetaMask SDK — React Native dep not needed in browser
      '@react-native-async-storage/async-storage': false,
      // WalletConnect / pino logger — optional, not needed in browser
      'pino-pretty': false,
      'lokijs':      false,
      'encoding':    false,
    }
    return config
  },
}

module.exports = nextConfig
