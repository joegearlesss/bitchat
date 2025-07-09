#!/usr/bin/env bun
// Build script for bitchat bridge server

import { log, ensureDir, formatBytes, formatDuration } from '../deploy/utils';

export interface BuildOptions {
  minify?: boolean;
  sourcemap?: boolean;
  target?: string;
  outdir?: string;
  watch?: boolean;
}

export class ProjectBuilder {
  private options: Required<BuildOptions>;

  constructor(options: BuildOptions = {}) {
    this.options = {
      minify: options.minify ?? true,
      sourcemap: options.sourcemap ?? false,
      target: options.target ?? 'browser',
      outdir: options.outdir ?? 'dist',
      watch: options.watch ?? false
    };
  }

  async build(): Promise<{
    success: boolean;
    outputPath: string;
    size: number;
    duration: number;
  }> {
    const startTime = Date.now();
    
    log.step('Building worker with Bun...');
    
    // Ensure output directory exists
    ensureDir(this.options.outdir);
    
    try {
      const buildResult = await Bun.build({
        entrypoints: ['src/index.ts'],
        outdir: this.options.outdir,
        target: 'browser',
        minify: this.options.minify,
        sourcemap: this.options.sourcemap ? 'external' : 'none',
        define: {
          'process.env.NODE_ENV': JSON.stringify(process.env.NODE_ENV || 'production')
        },
        external: []
      });

      if (!buildResult.success) {
        log.error('Build failed:');
        buildResult.logs.forEach(logEntry => {
          console.error(logEntry);
        });
        return {
          success: false,
          outputPath: '',
          size: 0,
          duration: Date.now() - startTime
        };
      }

      const outputPath = `${this.options.outdir}/index.js`;
      const file = Bun.file(outputPath);
      const size = file.size;
      const duration = Date.now() - startTime;

      log.success(`Worker built successfully in ${formatDuration(duration)}`);
      log.info(`Output: ${outputPath} (${formatBytes(size)})`);

      return {
        success: true,
        outputPath,
        size,
        duration
      };

    } catch (error) {
      log.error(`Build error: ${error}`);
      return {
        success: false,
        outputPath: '',
        size: 0,
        duration: Date.now() - startTime
      };
    }
  }

  async watch(): Promise<void> {
    log.info('Starting watch mode...');
    
    // TODO: Implement file watching
    // For now, we'll use Bun's built-in watch mode
    const proc = Bun.spawn(['bun', 'run', '--watch', 'src/index.ts'], {
      stdio: ['pipe', 'pipe', 'pipe']
    });

    log.info('Watching for file changes...');
    await proc.exited;
  }
}

// Main execution
async function main() {
  const args = process.argv.slice(2);
  const watch = args.includes('--watch');
  const minify = !args.includes('--no-minify');
  const sourcemap = args.includes('--sourcemap');
  
  const builder = new ProjectBuilder({
    minify,
    sourcemap,
    watch
  });

  if (watch) {
    await builder.watch();
  } else {
    const result = await builder.build();
    process.exit(result.success ? 0 : 1);
  }
}

// Run if called directly
if (import.meta.main) {
  main().catch(console.error);
}