import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { MobilecliDriver, resolveMobilecliBinary } from '@mobilewright/driver-mobilecli';

const exec = promisify(execFile);

// Mobilecli 1.0.18 prefers the Flutter VM tree on ARM64. That tree omits
// platform views and can expose offscreen widgets as actionable. Its raw
// Android dump bypasses Flutter and uses the same accessibility service as
// normalized native dumps on x86_64, where Flutter agent injection fails.
export class NativeAndroidDriver extends MobilecliDriver {
  constructor({ deviceId, ...options }) {
    super(options);
    this.deviceId = deviceId;
    this.binary = resolveMobilecliBinary(options.mobilecliPath);
  }

  async getViewHierarchy() {
    // Reuse the runner's private MOBILECLI_HOME/daemon. The child belongs to
    // the existing scenario process group and needs no separate server/socket.
    const { stdout } = await exec(this.binary, [
      'dump', 'ui', '--device', this.deviceId, '--format', 'raw',
    ], { timeout: 30_000, maxBuffer: 4 * 1024 * 1024 });
    const { rawData } = JSON.parse(stdout).data;
    // Do not silently fall back to Flutter if DeviceServer fails. The legacy
    // XML fallback is not the raw JSON contract supplied by the pinned helper.
    let tree;
    try {
      tree = JSON.parse(rawData);
    } catch (error) {
      throw new Error('Expected an Android DeviceServer JSON hierarchy', { cause: error });
    }
    if (!Array.isArray(tree.hierarchy)) {
      throw new Error('Android DeviceServer dump is missing its hierarchy');
    }
    return tree.hierarchy.map(viewNode);
  }
}

function viewNode(node) {
  return {
    type: node.class || 'text',
    text: node.text || undefined,
    label: node['content-desc'] || undefined,
    identifier: node['resource-id'] || undefined,
    resourceId: node['resource-id'] || undefined,
    placeholder: node.hint || undefined,
    isVisible: node.visible,
    isEnabled: node.enabled,
    isSelected: node.selected,
    isChecked: node.checked,
    isFocused: node.focused,
    bounds: node.rect,
    children: (node.children ?? []).map(viewNode),
    raw: node,
  };
}
