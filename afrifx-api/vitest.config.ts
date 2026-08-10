import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // Money-moving code: run tests serially so integration tests that touch a
    // scratch SQLite file can't race each other.
    fileParallelism: false,
    include: ['tests/**/*.test.ts'],
    environment: 'node',
  },
})
