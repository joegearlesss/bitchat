#!/usr/bin/env bun
// Deployment testing script for bitchat bridge

import { log, sleep, retry } from '../deploy/utils';

export interface HealthCheckResult {
  endpoint: string;
  status: number;
  responseTime: number;
  success: boolean;
  error?: string;
}

export class DeploymentTester {
  private baseUrls: string[];

  constructor(baseUrls: string[]) {
    this.baseUrls = baseUrls;
  }

  async testEndpoints(): Promise<HealthCheckResult[]> {
    log.step('Testing deployed endpoints...');
    
    const results: HealthCheckResult[] = [];
    
    for (const baseUrl of this.baseUrls) {
      const endpoints = [
        `${baseUrl}/health`,
        `${baseUrl}/bridges`,
        `${baseUrl}/bridge/global/stats`
      ];
      
      for (const endpoint of endpoints) {
        const result = await this.testEndpoint(endpoint);
        results.push(result);
        
        if (result.success) {
          log.success(`✓ ${endpoint} (${result.responseTime}ms)`);
        } else {
          log.error(`✗ ${endpoint} - ${result.error}`);
        }
      }
    }
    
    return results;
  }

  private async testEndpoint(url: string): Promise<HealthCheckResult> {
    const startTime = Date.now();
    
    try {
      const response = await retry(
        () => fetch(url, { 
          method: 'GET',
          headers: {
            'User-Agent': 'bitchat-bridge-tester/1.0'
          }
        }),
        3,
        2000
      );
      
      const responseTime = Date.now() - startTime;
      
      return {
        endpoint: url,
        status: response.status,
        responseTime,
        success: response.ok
      };
      
    } catch (error) {
      return {
        endpoint: url,
        status: 0,
        responseTime: Date.now() - startTime,
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error'
      };
    }
  }

  async testWebSocketConnection(wsUrl: string): Promise<boolean> {
    log.step(`Testing WebSocket connection: ${wsUrl}`);
    
    return new Promise((resolve) => {
      const ws = new WebSocket(wsUrl);
      let resolved = false;
      
      const timeout = setTimeout(() => {
        if (!resolved) {
          resolved = true;
          ws.close();
          log.error('WebSocket connection timeout');
          resolve(false);
        }
      }, 10000);
      
      ws.onopen = () => {
        if (!resolved) {
          resolved = true;
          clearTimeout(timeout);
          log.success('WebSocket connection successful');
          ws.close();
          resolve(true);
        }
      };
      
      ws.onerror = (error) => {
        if (!resolved) {
          resolved = true;
          clearTimeout(timeout);
          log.error(`WebSocket connection failed: ${error}`);
          resolve(false);
        }
      };
    });
  }

  async runFullTest(): Promise<{
    success: boolean;
    results: HealthCheckResult[];
    websocketSuccess: boolean;
  }> {
    const results = await this.testEndpoints();
    const allEndpointsHealthy = results.every(r => r.success);
    
    // Test WebSocket connection to first URL
    let websocketSuccess = false;
    if (this.baseUrls.length > 0) {
      const wsUrl = this.baseUrls[0].replace('https://', 'wss://') + '/bridge/global';
      websocketSuccess = await this.testWebSocketConnection(wsUrl);
    }
    
    const success = allEndpointsHealthy && websocketSuccess;
    
    if (success) {
      log.success('All deployment tests passed!');
    } else {
      log.error('Some deployment tests failed');
    }
    
    return {
      success,
      results,
      websocketSuccess
    };
  }
}

// Main execution
async function main() {
  const args = process.argv.slice(2);
  const environment = args.find(arg => arg.startsWith('--env='))?.split('=')[1] || 'staging';
  
  const urls = environment === 'production' 
    ? ['https://bridge.bitchat.app']
    : ['https://bridge-staging.bitchat.app'];
  
  const tester = new DeploymentTester(urls);
  const result = await tester.runFullTest();
  
  process.exit(result.success ? 0 : 1);
}

// Run if called directly
if (import.meta.main) {
  main().catch(console.error);
}

export { DeploymentTester };