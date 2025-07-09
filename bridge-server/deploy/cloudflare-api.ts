// Native Cloudflare API client for bitchat bridge deployment

import type { 
  CloudflareResponse, 
  WorkerScript, 
  DurableObjectNamespace, 
  WorkerRoute, 
  WorkerMetadata 
} from '../src/types';

export class CloudflareAPI {
  private apiToken: string;
  private accountId: string;
  private baseURL = 'https://api.cloudflare.com/client/v4';

  constructor(apiToken: string, accountId: string) {
    this.apiToken = apiToken;
    this.accountId = accountId;
  }

  private async request<T = any>(
    endpoint: string, 
    options: RequestInit = {}
  ): Promise<CloudflareResponse<T>> {
    const url = `${this.baseURL}${endpoint}`;
    const response = await fetch(url, {
      ...options,
      headers: {
        'Authorization': `Bearer ${this.apiToken}`,
        'Content-Type': 'application/json',
        ...options.headers
      }
    });

    const data = await response.json() as CloudflareResponse<T>;

    if (!response.ok || !data.success) {
      const errorMessage = data.errors?.map(e => e.message).join(', ') || 'Unknown error';
      throw new Error(`Cloudflare API error (${response.status}): ${errorMessage}`);
    }

    return data;
  }

  async uploadWorkerScript(
    scriptName: string, 
    scriptContent: string, 
    metadata: WorkerMetadata
  ): Promise<WorkerScript> {
    const formData = new FormData();
    
    // Add the main script file
    formData.append('index.js', new Blob([scriptContent], { type: 'application/javascript' }), 'index.js');
    
    // Add metadata
    formData.append('metadata', JSON.stringify({
      ...metadata,
      bindings: metadata.bindings || []
    }));

    const response = await fetch(
      `${this.baseURL}/accounts/${this.accountId}/workers/scripts/${scriptName}`,
      {
        method: 'PUT',
        headers: {
          'Authorization': `Bearer ${this.apiToken}`
        },
        body: formData
      }
    );

    const data = await response.json() as CloudflareResponse<WorkerScript>;

    if (!response.ok || !data.success) {
      const errorMessage = data.errors?.map(e => e.message).join(', ') || 'Upload failed';
      throw new Error(`Worker upload failed (${response.status}): ${errorMessage}`);
    }

    return data.result;
  }

  async createDurableObjectNamespace(
    name: string, 
    className: string, 
    scriptName: string
  ): Promise<DurableObjectNamespace> {
    const response = await this.request<DurableObjectNamespace>(
      `/accounts/${this.accountId}/workers/durable_objects/namespaces`,
      {
        method: 'POST',
        body: JSON.stringify({
          name,
          class: className,
          script: scriptName
        })
      }
    );
    return response.result;
  }

  async updateDurableObjectNamespace(
    namespaceId: string, 
    className: string, 
    scriptName: string
  ): Promise<DurableObjectNamespace> {
    const response = await this.request<DurableObjectNamespace>(
      `/accounts/${this.accountId}/workers/durable_objects/namespaces/${namespaceId}`,
      {
        method: 'PUT',
        body: JSON.stringify({
          class: className,
          script: scriptName
        })
      }
    );
    return response.result;
  }

  async listDurableObjectNamespaces(): Promise<DurableObjectNamespace[]> {
    const response = await this.request<DurableObjectNamespace[]>(
      `/accounts/${this.accountId}/workers/durable_objects/namespaces`
    );
    return response.result;
  }

  async getDurableObjectNamespace(namespaceId: string): Promise<DurableObjectNamespace> {
    const response = await this.request<DurableObjectNamespace>(
      `/accounts/${this.accountId}/workers/durable_objects/namespaces/${namespaceId}`
    );
    return response.result;
  }

  async deleteDurableObjectNamespace(namespaceId: string): Promise<void> {
    await this.request(
      `/accounts/${this.accountId}/workers/durable_objects/namespaces/${namespaceId}`,
      { method: 'DELETE' }
    );
  }

  async createRoute(zoneId: string, pattern: string, scriptName: string): Promise<WorkerRoute> {
    const response = await this.request<WorkerRoute>(
      `/zones/${zoneId}/workers/routes`,
      {
        method: 'POST',
        body: JSON.stringify({
          pattern,
          script: scriptName
        })
      }
    );
    return response.result;
  }

  async listRoutes(zoneId: string): Promise<WorkerRoute[]> {
    const response = await this.request<WorkerRoute[]>(`/zones/${zoneId}/workers/routes`);
    return response.result;
  }

  async updateRoute(zoneId: string, routeId: string, scriptName: string): Promise<WorkerRoute> {
    const response = await this.request<WorkerRoute>(
      `/zones/${zoneId}/workers/routes/${routeId}`,
      {
        method: 'PUT',
        body: JSON.stringify({
          script: scriptName
        })
      }
    );
    return response.result;
  }

  async deleteRoute(zoneId: string, routeId: string): Promise<void> {
    await this.request(`/zones/${zoneId}/workers/routes/${routeId}`, {
      method: 'DELETE'
    });
  }

  async getWorkerScript(scriptName: string): Promise<WorkerScript> {
    const response = await this.request<WorkerScript>(
      `/accounts/${this.accountId}/workers/scripts/${scriptName}`
    );
    return response.result;
  }

  async deleteWorkerScript(scriptName: string): Promise<void> {
    await this.request(`/accounts/${this.accountId}/workers/scripts/${scriptName}`, {
      method: 'DELETE'
    });
  }

  async listWorkerScripts(): Promise<WorkerScript[]> {
    const response = await this.request<WorkerScript[]>(
      `/accounts/${this.accountId}/workers/scripts`
    );
    return response.result;
  }

  async validateCredentials(): Promise<boolean> {
    try {
      // Test actual Workers API access instead of token verification
      await this.request(`/accounts/${this.accountId}/workers/scripts`);
      return true;
    } catch {
      return false;
    }
  }
}