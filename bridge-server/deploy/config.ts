// Deployment configuration for bitchat bridge

export interface DeploymentConfig {
  scriptName: string;
  compatibilityDate: string;
  compatibilityFlags: string[];
  durableObjects: DurableObjectConfig[];
  routes: RouteConfig[];
}

export interface DurableObjectConfig {
  name: string;
  className: string;
  scriptName?: string;
}

export interface RouteConfig {
  pattern: string;
  zone: string;
}

export const deploymentConfigs: Record<string, DeploymentConfig> = {
  staging: {
    scriptName: "bitchat-bridge-staging",
    compatibilityDate: "2024-01-01",
    compatibilityFlags: ["nodejs_compat"],
    durableObjects: [
      {
        name: "BRIDGE_RELAY",
        className: "BridgeRelay"
      }
    ],
    routes: [] // No custom domain routes - use default worker URL
  },
  
  production: {
    scriptName: "bitchat-bridge",
    compatibilityDate: "2024-01-01",
    compatibilityFlags: ["nodejs_compat"],
    durableObjects: [
      {
        name: "BRIDGE_RELAY",
        className: "BridgeRelay"
      }
    ],
    routes: [] // No custom domain routes - use default worker URL
  }
};

export const getConfig = (env: string = 'staging'): DeploymentConfig => {
  const config = deploymentConfigs[env];
  if (!config) {
    throw new Error(`Unknown environment: ${env}`);
  }
  return config;
};