// Deployment utilities for bitchat bridge

import { createWriteStream, existsSync, mkdirSync } from 'fs';
import { join } from 'path';

export const colors = {
  reset: '\x1b[0m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m',
  white: '\x1b[37m',
  gray: '\x1b[90m'
} as const;

export const log = {
  info: (msg: string) => console.log(`${colors.blue}ℹ${colors.reset} ${msg}`),
  success: (msg: string) => console.log(`${colors.green}✅${colors.reset} ${msg}`),
  warning: (msg: string) => console.log(`${colors.yellow}⚠${colors.reset} ${msg}`),
  error: (msg: string) => console.log(`${colors.red}❌${colors.reset} ${msg}`),
  step: (msg: string) => console.log(`${colors.cyan}🔧${colors.reset} ${msg}`),
  debug: (msg: string) => console.log(`${colors.gray}🐛${colors.reset} ${msg}`)
} as const;

export function ensureDir(dirPath: string): void {
  if (!existsSync(dirPath)) {
    mkdirSync(dirPath, { recursive: true });
  }
}

export function validateEnvironmentVariables(requireZoneIds: boolean = false): {
  apiToken: string;
  accountId: string;
} {
  const apiToken = process.env.CLOUDFLARE_API_TOKEN;
  const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
  
  if (!apiToken) {
    throw new Error('Missing required environment variable: CLOUDFLARE_API_TOKEN');
  }
  
  if (!accountId) {
    throw new Error('Missing required environment variable: CLOUDFLARE_ACCOUNT_ID');
  }
  
  // Only validate zone IDs if custom domains are configured
  if (requireZoneIds) {
    const zoneId = process.env.CLOUDFLARE_ZONE_ID;
    const zoneIdStaging = process.env.CLOUDFLARE_ZONE_ID_STAGING;
    
    if (!zoneId) {
      log.warning('CLOUDFLARE_ZONE_ID not set - production will use default worker URL');
    }
    
    if (!zoneIdStaging) {
      log.warning('CLOUDFLARE_ZONE_ID_STAGING not set - staging will use default worker URL');
    }
  }
  
  return { apiToken, accountId };
}

export function parseArguments(args: string[]): {
  environment: string;
  isCleanup: boolean;
  isDryRun: boolean;
  verbose: boolean;
} {
  const envFlag = args.find(arg => arg.startsWith('--env='));
  const environment = envFlag ? envFlag.split('=')[1] : 'staging';
  const isCleanup = args.includes('--cleanup');
  const isDryRun = args.includes('--dry-run');
  const verbose = args.includes('--verbose') || args.includes('-v');
  
  return { environment, isCleanup, isDryRun, verbose };
}

export async function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

export async function retry<T>(
  fn: () => Promise<T>,
  maxAttempts: number = 3,
  delayMs: number = 1000
): Promise<T> {
  let lastError: Error;
  
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error as Error;
      
      if (attempt === maxAttempts) {
        break;
      }
      
      log.warning(`Attempt ${attempt} failed, retrying in ${delayMs}ms...`);
      await sleep(delayMs);
      delayMs *= 2; // Exponential backoff
    }
  }
  
  throw lastError!;
}

export function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${(bytes / Math.pow(k, i)).toFixed(1)} ${sizes[i]}`;
}

export function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
  return `${(ms / 60000).toFixed(1)}m`;
}

export class ProgressSpinner {
  private spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
  private current = 0;
  private interval?: Timer;
  private message: string;

  constructor(message: string) {
    this.message = message;
  }

  start(): void {
    process.stdout.write(`${this.spinner[0]} ${this.message}`);
    this.interval = setInterval(() => {
      this.current = (this.current + 1) % this.spinner.length;
      process.stdout.write(`\r${this.spinner[this.current]} ${this.message}`);
    }, 100);
  }

  stop(finalMessage?: string): void {
    if (this.interval) {
      clearInterval(this.interval);
      this.interval = undefined;
    }
    process.stdout.write(`\r${finalMessage || this.message}\n`);
  }
}

export async function writeDeploymentReport(
  environment: string,
  deploymentData: any
): Promise<void> {
  const reportsDir = 'deploy/reports';
  ensureDir(reportsDir);
  
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const reportFile = join(reportsDir, `deployment-${environment}-${timestamp}.json`);
  
  const report = {
    timestamp: new Date().toISOString(),
    environment,
    success: deploymentData.success,
    duration: deploymentData.duration,
    scriptName: deploymentData.scriptName,
    scriptSize: deploymentData.scriptSize,
    durableObjects: deploymentData.durableObjects,
    routes: deploymentData.routes,
    errors: deploymentData.errors || []
  };
  
  await Bun.write(reportFile, JSON.stringify(report, null, 2));
  log.info(`Deployment report saved: ${reportFile}`);
}