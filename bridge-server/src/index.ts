// Main Cloudflare Worker entry point for bitchat bridge

import { BridgeRelay } from './bridge-relay';
import type { Env } from './types';

export { BridgeRelay };

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    
    // Handle different endpoints
    if (path.startsWith('/bridge/')) {
      const bridgeId = path.split('/')[2] || 'global';
      const id = env.BRIDGE_RELAY.idFromName(bridgeId);
      const obj = env.BRIDGE_RELAY.get(id);
      return obj.fetch(request);
    }
    
    if (path === '/health') {
      return new Response('OK', { 
        status: 200,
        headers: {
          'Content-Type': 'text/plain',
          'Cache-Control': 'no-cache'
        }
      });
    }
    
    if (path === '/bridges') {
      return new Response(JSON.stringify({
        endpoints: [
          { id: 'global', region: 'auto', status: 'healthy' },
          { id: 'us-east', region: 'us-east-1', status: 'healthy' },
          { id: 'eu-west', region: 'eu-west-1', status: 'healthy' },
          { id: 'ap-southeast', region: 'ap-southeast-1', status: 'healthy' }
        ]
      }), {
        headers: { 
          'Content-Type': 'application/json',
          'Cache-Control': 'no-cache'
        }
      });
    }
    
    // CORS preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type, Authorization',
          'Access-Control-Max-Age': '86400'
        }
      });
    }
    
    return new Response('Not Found', { status: 404 });
  }
};