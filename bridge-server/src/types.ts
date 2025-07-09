// Type definitions for bitchat bridge server

export interface Env {
  BRIDGE_RELAY: DurableObjectNamespace;
}

export interface BridgeMessage {
  type: 'heartbeat' | 'data' | 'subscribe' | 'unsubscribe';
  payload?: {
    encryptedData: number[];
    signature: number[];
    ttl?: number;
    timestamp: number;
  };
  channel?: string;
}

export interface BufferedMessage {
  message: any;
  timestamp: number;
  fromSessionId: string;
}

export interface BridgeStats {
  totalMessages: number;
  activeConnections: number;
  uptime: number;
  messagesPerSecond: number;
}

export interface WorkerMetadata {
  main_module: string;
  compatibility_date: string;
  compatibility_flags: string[];
  bindings: WorkerBinding[];
}

export interface WorkerBinding {
  name: string;
  type: string;
  class_name?: string;
  script_name?: string;
}

export interface CloudflareResponse<T = any> {
  success: boolean;
  errors: Array<{ code: number; message: string }>;
  messages: Array<{ code: number; message: string }>;
  result: T;
}

export interface WorkerScript {
  id: string;
  etag: string;
  size: number;
  modified_on: string;
}

export interface DurableObjectNamespace {
  id: string;
  name: string;
  script: string;
  class: string;
}

export interface WorkerRoute {
  id: string;
  pattern: string;
  script?: string;
  zone_id: string;
  zone_name: string;
}