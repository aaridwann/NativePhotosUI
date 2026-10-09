import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

export type PhotoPermissionStatus = 'authorized' | 'denied' | 'restricted' | 'notDetermined' | 'limited';

export type PhotoPickerFilter = 'images' | 'videos' | 'livePhotos' | 'any';

export interface PickerOptions {
  selectionLimit?: number;
  filter?: PhotoPickerFilter;
  preferredAssetRepresentationMode?: 'automatic' | 'current' | 'compatible';
}

export interface PickerResult {
  uri: string;
  mediaType: 'image' | 'video' | 'livePhoto';
  fileName: string;
  mimeType: string;
  width?: number;
  height?: number;
  fileSize?: number;
}

export interface Spec extends TurboModule {
  requestPermission(accessLevel: 'readWrite' | 'addOnly'): Promise<PhotoPermissionStatus>;
  getPermissionStatus(accessLevel: 'readWrite' | 'addOnly'): Promise<PhotoPermissionStatus>;
  presentPicker(options: PickerOptions): Promise<PickerResult[]>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('NativePhotosUI');