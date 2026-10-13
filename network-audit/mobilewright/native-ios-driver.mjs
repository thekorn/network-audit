import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { MobilecliDriver, resolveMobilecliBinary } from '@mobilewright/driver-mobilecli';

const exec = promisify(execFile);

// Mobilecli 1.0.18 substitutes Flutter's render tree for normal Simulator
// dumps. Raw DeviceKit snapshots retain embedded WKWebView accessibility nodes.
export class NativeIOSDriver extends MobilecliDriver {
  constructor({ deviceId, ...options }) {
    super(options);
    this.deviceId = deviceId;
    this.binary = resolveMobilecliBinary(options.mobilecliPath);
  }

  async getViewHierarchy() {
    // Keep the run's private daemon and process group, just like Android.
    const { stdout } = await exec(this.binary, [
      'dump', 'ui', '--device', this.deviceId, '--format', 'raw',
    ], { timeout: 30_000, maxBuffer: 4 * 1024 * 1024 });
    return [viewNode(JSON.parse(stdout).data?.rawData)];
  }
}

// DeviceKit 0.0.33's AXElement -> SourceTreeElement type names:
// https://github.com/mobile-next/devicekit-ios/blob/0.0.33/DeviceKitTests/XCTest/AXElement.swift
const elementTypes = {
  0: 'Any', 1: 'Other', 2: 'Application', 3: 'Group', 4: 'Window',
  5: 'Sheet', 6: 'Drawer', 7: 'Alert', 8: 'Dialog', 9: 'Button',
  10: 'RadioButton', 11: 'RadioGroup', 12: 'CheckBox',
  13: 'DisclosureTriangle', 14: 'PopUpButton', 15: 'ComboBox',
  16: 'MenuButton', 17: 'ToolbarButton', 18: 'Popover',
  19: 'Keyboard', 20: 'Key', 21: 'NavigationBar', 22: 'TabBar',
  23: 'TabGroup', 24: 'Toolbar', 25: 'StatusBar', 26: 'Table',
  27: 'TableRow', 28: 'TableColumn', 29: 'Outline', 30: 'OutlineRow',
  31: 'Browser', 32: 'CollectionView', 33: 'Slider',
  34: 'PageIndicator', 35: 'ProgressIndicator',
  36: 'ActivityIndicator', 37: 'SegmentedControl', 38: 'Picker',
  39: 'PickerWheel', 40: 'Switch', 41: 'Toggle', 42: 'Link',
  43: 'Image', 44: 'Icon', 45: 'SearchField', 46: 'ScrollView',
  47: 'ScrollBar', 48: 'StaticText', 49: 'TextField',
  50: 'SecureTextField', 51: 'DatePicker', 52: 'TextView',
  53: 'Menu', 54: 'MenuItem', 55: 'MenuBar', 56: 'MenuBarItem',
  57: 'Map', 58: 'WebView', 59: 'IncrementArrow',
  60: 'DecrementArrow', 61: 'Timeline', 62: 'RatingIndicator',
  63: 'ValueIndicator', 64: 'SplitGroup', 65: 'Splitter',
  66: 'RelevanceIndicator', 67: 'ColorWell', 68: 'HelpTag',
  69: 'Matte', 70: 'DockItem', 71: 'Ruler', 72: 'RulerMarker',
  73: 'Grid', 74: 'LevelIndicator', 75: 'Cell', 76: 'LayoutArea',
  77: 'LayoutItem', 78: 'Handle', 79: 'Stepper', 80: 'Tab',
  81: 'TouchBar', 82: 'StatusItem',
};

function viewNode(node) {
  const frame = node?.frame;
  if (!Number.isInteger(node?.elementType) || !frame ||
      !['X', 'Y', 'Width', 'Height'].every((key) => Number.isFinite(frame[key])) ||
      (node.children != null && !Array.isArray(node.children))) {
    throw new Error('Expected an iOS DeviceKit AX hierarchy');
  }
  const type = elementTypes[node.elementType] ?? 'Unknown';
  // AX frames and Simulator taps both use logical screen points, not pixels.
  const bounds = { x: frame.X, y: frame.Y, width: frame.Width, height: frame.Height };
  return {
    type,
    label: node.label || undefined,
    value: node.value || undefined,
    identifier: node.identifier || undefined,
    placeholder: node.placeholderValue || undefined,
    isVisible: bounds.x >= 0 && bounds.y >= 0 && bounds.width > 0 && bounds.height > 0,
    isEnabled: node.enabled ?? true,
    isSelected: node.selected ?? false,
    isChecked: type === 'Switch' && node.value === '1',
    isFocused: node.hasFocus ?? false,
    bounds,
    children: (node.children ?? []).map(viewNode),
    raw: node,
  };
}
