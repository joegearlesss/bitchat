#!/usr/bin/env bun
// Main deployment script for bitchat bridge

import { CloudflareAPI } from './cloudflare-api';
import { getConfig, type DeploymentConfig } from './config';
import { 
  log, 
  validateEnvironmentVariables, 
  parseArguments,
  ProgressSpinner,
  retry,
  formatBytes,
  formatDuration,
  writeDeploymentReport
} from './utils';
import { ProjectBuilder } from '../scripts/build';
import type { WorkerMetadata } from '../src/types';

export class BitchatBridgeDeployer {
  private api: CloudflareAPI;
  private config: DeploymentConfig;
  private environment: string;
  private isDryRun: boolean;
  private verbose: boolean;

  constructor(environment: string = 'staging', isDryRun: boolean = false, verbose: boolean = false) {
    this.environment = environment;
    this.isDryRun = isDryRun;
    this.verbose = verbose;
    this.config = getConfig(environment);
    
    const { apiToken, accountId } = validateEnvironmentVariables(this.config.routes.length > 0);
    this.api = new CloudflareAPI(apiToken, accountId);
  }

  async deploy(): Promise<{
    success: boolean;
    scriptName: string;
    scriptSize: number;
    duration: number;
    errors: string[];
  }> {
    const startTime = Date.now();
    const errors: string[] = [];
    
    log.info(`🚀 Starting deployment to ${this.environment}${this.isDryRun ? ' (DRY RUN)' : ''}...`);
    
    try {
      // Validate credentials first
      await this.validateCredentials();
      
      // Step 1: Build the worker
      const buildResult = await this.buildWorker();
      if (!buildResult.success) {
        throw new Error('Build failed');
      }
      
      // Step 2: Upload worker script
      await this.uploadWorkerScript(buildResult.outputPath);
      
      // Step 3: Setup Durable Objects
      await this.setupDurableObjects();
      
      // Step 4: Configure routes
      await this.configureRoutes();
      
      const duration = Date.now() - startTime;
      
      // Write deployment report
      await writeDeploymentReport(this.environment, {
        success: true,
        duration,
        scriptName: this.config.scriptName,
        scriptSize: buildResult.size,
        durableObjects: this.config.durableObjects,
        routes: this.config.routes,
        errors
      });
      
      log.success(`🎉 Deployment to ${this.environment} completed successfully in ${formatDuration(duration)}!`);
      log.info(`🌐 Bridge available at: https://${this.config.routes[0]?.pattern.replace('/*', '')}`);
      
      return {
        success: true,
        scriptName: this.config.scriptName,
        scriptSize: buildResult.size,
        duration,
        errors
      };
      
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      errors.push(errorMessage);
      
      await writeDeploymentReport(this.environment, {
        success: false,
        duration: Date.now() - startTime,
        scriptName: this.config.scriptName,
        scriptSize: 0,
        durableObjects: this.config.durableObjects,
        routes: this.config.routes,
        errors
      });
      
      log.error(`❌ Deployment failed: ${errorMessage}`);
      
      return {
        success: false,
        scriptName: this.config.scriptName,
        scriptSize: 0,
        duration: Date.now() - startTime,
        errors
      };
    }
  }

  private async validateCredentials(): Promise<void> {
    const spinner = new ProgressSpinner('Validating Cloudflare credentials...');
    spinner.start();
    
    try {
      const isValid = await this.api.validateCredentials();
      if (!isValid) {
        throw new Error('Invalid Cloudflare API credentials');
      }
      spinner.stop('✅ Credentials validated');
    } catch (error) {
      spinner.stop('❌ Credential validation failed');
      throw error;
    }
  }

  private async buildWorker(): Promise<{
    success: boolean;
    outputPath: string;
    size: number;
  }> {
    log.step('Building worker with Bun...');
    
    const builder = new ProjectBuilder({
      minify: true,
      sourcemap: false
    });
    
    const result = await builder.build();
    
    if (!result.success) {
      throw new Error('Worker build failed');
    }
    
    return result;
  }

  private async uploadWorkerScript(scriptPath: string): Promise<void> {
    if (this.isDryRun) {
      log.info('DRY RUN: Would upload worker script');
      return;
    }
    
    const spinner = new ProgressSpinner('Uploading worker script...');
    spinner.start();
    
    try {
      const scriptContent = await Bun.file(scriptPath).text();
      const scriptSize = new Blob([scriptContent]).size;
      
      const metadata: WorkerMetadata = {
        main_module: 'index.js',
        compatibility_date: this.config.compatibilityDate,
        compatibility_flags: this.config.compatibilityFlags,
        bindings: this.config.durableObjects.map(obj => ({
          name: obj.name,
          type: 'durable_object_namespace',
          class_name: obj.className
        }))
      };

      await retry(
        () => this.api.uploadWorkerScript(this.config.scriptName, scriptContent, metadata),
        3,
        2000
      );

      spinner.stop(`✅ Worker script uploaded (${formatBytes(scriptSize)})`);
      
    } catch (error) {
      spinner.stop('❌ Worker upload failed');
      throw error;
    }
  }

  private async setupDurableObjects(): Promise<void> {
    if (this.isDryRun) {
      log.info('DRY RUN: Would setup Durable Objects');
      return;
    }
    
    log.step('Setting up Durable Objects...');
    
    for (const obj of this.config.durableObjects) {
      const spinner = new ProgressSpinner(`Setting up ${obj.name}...`);
      spinner.start();
      
      try {
        // Check if namespace already exists
        const namespaces = await this.api.listDurableObjectNamespaces();
        const existing = namespaces.find(ns => ns.name === obj.name);
        
        if (existing) {
          if (this.verbose) {
            log.info(`Updating existing Durable Object namespace: ${obj.name}`);
          }
          await this.api.updateDurableObjectNamespace(
            existing.id,
            obj.className,
            this.config.scriptName
          );
        } else {
          if (this.verbose) {
            log.info(`Creating new Durable Object namespace: ${obj.name}`);
          }
          await this.api.createDurableObjectNamespace(
            obj.name,
            obj.className,
            this.config.scriptName
          );
        }
        
        spinner.stop(`✅ Durable Object ${obj.name} configured`);
        
      } catch (error) {
        spinner.stop(`⚠️ Durable Object ${obj.name} setup had issues`);
        log.warning(`Failed to setup Durable Object ${obj.name}: ${error}`);
        // Continue with deployment - might be a permissions issue
      }
    }
  }

  private async configureRoutes(): Promise<void> {
    if (this.config.routes.length === 0) {
      log.info('No custom routes configured - using default worker URL');
      return;
    }
    
    if (this.isDryRun) {
      log.info('DRY RUN: Would configure routes');
      return;
    }
    
    log.step('Configuring routes...');
    
    for (const route of this.config.routes) {
      const spinner = new ProgressSpinner(`Configuring route ${route.pattern}...`);
      spinner.start();
      
      try {
        // Clean up existing routes first
        const existingRoutes = await this.api.listRoutes(route.zone);
        const conflicting = existingRoutes.filter(r => 
          r.pattern === route.pattern && r.script !== this.config.scriptName
        );
        
        for (const conflictRoute of conflicting) {
          if (this.verbose) {
            log.info(`Removing conflicting route: ${conflictRoute.pattern}`);
          }
          await this.api.deleteRoute(route.zone, conflictRoute.id);
        }
        
        // Check if route already exists for our script
        const existingForScript = existingRoutes.find(r => 
          r.pattern === route.pattern && r.script === this.config.scriptName
        );
        
        if (existingForScript) {
          // Route already exists, update it
          await this.api.updateRoute(route.zone, existingForScript.id, this.config.scriptName);
        } else {
          // Create new route
          await this.api.createRoute(route.zone, route.pattern, this.config.scriptName);
        }
        
        spinner.stop(`✅ Route configured: ${route.pattern}`);
        
      } catch (error) {
        spinner.stop(`⚠️ Route ${route.pattern} configuration failed`);
        log.warning(`Failed to configure route ${route.pattern}: ${error}`);
      }
    }
  }

  async cleanup(): Promise<void> {
    if (this.isDryRun) {
      log.info('DRY RUN: Would cleanup deployment');
      return;
    }
    
    log.step(`🧹 Cleaning up deployment for ${this.environment}...`);
    
    try {
      // Remove routes
      for (const route of this.config.routes) {
        const spinner = new ProgressSpinner(`Removing route ${route.pattern}...`);
        spinner.start();
        
        try {
          const routes = await this.api.listRoutes(route.zone);
          const matching = routes.filter(r => 
            r.pattern === route.pattern && r.script === this.config.scriptName
          );
          
          for (const matchRoute of matching) {
            await this.api.deleteRoute(route.zone, matchRoute.id);
          }
          
          spinner.stop(`✅ Route removed: ${route.pattern}`);
        } catch (error) {
          spinner.stop(`⚠️ Route removal failed: ${route.pattern}`);
        }
      }
      
      // Remove Durable Object namespaces
      const namespaces = await this.api.listDurableObjectNamespaces();
      for (const obj of this.config.durableObjects) {
        const existing = namespaces.find(ns => ns.name === obj.name);
        if (existing) {
          const spinner = new ProgressSpinner(`Removing namespace ${obj.name}...`);
          spinner.start();
          
          try {
            await this.api.deleteDurableObjectNamespace(existing.id);
            spinner.stop(`✅ Durable Object namespace removed: ${obj.name}`);
          } catch (error) {
            spinner.stop(`⚠️ Namespace removal failed: ${obj.name}`);
          }
        }
      }
      
      // Remove worker
      const spinner = new ProgressSpinner(`Removing worker ${this.config.scriptName}...`);
      spinner.start();
      
      try {
        await this.api.deleteWorkerScript(this.config.scriptName);
        spinner.stop(`✅ Worker script removed: ${this.config.scriptName}`);
      } catch (error) {
        spinner.stop(`⚠️ Worker script may not exist: ${this.config.scriptName}`);
      }
      
      log.success('🧹 Cleanup completed successfully!');
      
    } catch (error) {
      log.error(`Cleanup failed: ${error}`);
      throw error;
    }
  }
}

// Main execution
async function main() {
  const args = process.argv.slice(2);
  const { environment, isCleanup, isDryRun, verbose } = parseArguments(args);
  
  const deployer = new BitchatBridgeDeployer(environment, isDryRun, verbose);
  
  try {
    if (isCleanup) {
      await deployer.cleanup();
    } else {
      const result = await deployer.deploy();
      process.exit(result.success ? 0 : 1);
    }
  } catch (error) {
    log.error(`Operation failed: ${error}`);
    process.exit(1);
  }
}

// Run if called directly
if (import.meta.main) {
  main().catch(console.error);
}

