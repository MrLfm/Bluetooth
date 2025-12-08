//
//  GamepadManager.h
//  Bluetooth
//
//  Created by FumingLeo on 2025/11/28.
//
//  蓝牙手柄管理器 - 示例代码
//  展示了如何正确处理iOS蓝牙开发中的常见问题

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

@class CBPeripheral;
@class CBCharacteristic;

/// 连接状态
typedef NS_ENUM(NSInteger, GamepadConnectionState) {
    GamepadConnectionStateDisconnected = 0,  // 未连接
    GamepadConnectionStateConnecting,        // 连接中
    GamepadConnectionStateConnected,         // 已连接
    GamepadConnectionStateDisconnecting      // 断开中
};

/// 连接进度回调
typedef void(^GamepadConnectionProgressBlock)(CGFloat progress, NSString *status);

/// 连接结果回调
typedef void(^GamepadConnectionResultBlock)(BOOL success, NSError * _Nullable error);

/// 设备发现回调
typedef void(^GamepadDiscoveryBlock)(CBPeripheral *peripheral, NSNumber *RSSI);

/// 电池电量回调
typedef void(^GamepadBatteryBlock)(NSInteger batteryLevel);

/// 错误回调
typedef void(^GamepadErrorBlock)(NSError *error);

/**
 * 蓝牙手柄管理器
 * 
 * 功能特性：
 * 1. 线程安全的CoreBluetooth回调处理
 * 2. 完善的连接状态管理
 * 3. 连接超时机制
 * 4. 数据写入队列和频率限制
 * 5. 完善的错误处理
 * 6. 后台运行支持
 * 7. iOS版本兼容性处理
 */
@interface GamepadManager : NSObject

/// 单例
+ (instancetype)sharedManager;

/// 当前连接状态
@property (nonatomic, assign, readonly) GamepadConnectionState connectionState;

/// 当前连接的设备
@property (nonatomic, strong, readonly, nullable) CBPeripheral *connectedPeripheral;

/// 连接超时时间（默认10秒）
@property (nonatomic, assign) NSTimeInterval connectionTimeout;

/// 设备发现回调
@property (nonatomic, copy, nullable) GamepadDiscoveryBlock discoveryBlock;

/// 电池电量回调
@property (nonatomic, copy, nullable) GamepadBatteryBlock batteryBlock;

/// 错误回调
@property (nonatomic, copy, nullable) GamepadErrorBlock errorBlock;

#pragma mark - 扫描和连接

/// 开始扫描设备
/// @param serviceUUIDs 要扫描的Service UUID数组，nil表示扫描所有设备（前台），后台必须指定UUID
- (void)startScanningWithServiceUUIDs:(nullable NSArray<CBUUID *> *)serviceUUIDs;

/// 停止扫描
- (void)stopScanning;

/// 连接设备
/// @param peripheral 要连接的设备
/// @param progressBlock 连接进度回调
/// @param resultBlock 连接结果回调
- (void)connectPeripheral:(CBPeripheral *)peripheral
                 progress:(nullable GamepadConnectionProgressBlock)progressBlock
                   result:(nullable GamepadConnectionResultBlock)resultBlock;

/// 断开连接
- (void)disconnect;

#pragma mark - 数据读写

/// 写入数据（带频率限制）
/// @param data 要写入的数据
/// @param characteristic 特征值
/// @param completion 完成回调
- (void)writeData:(NSData *)data
 toCharacteristic:(CBCharacteristic *)characteristic
       completion:(nullable void(^)(NSError * _Nullable error))completion;

/// 读取数据
/// @param characteristic 特征值
/// @param completion 完成回调
- (void)readDataFromCharacteristic:(CBCharacteristic *)characteristic
                         completion:(nullable void(^)(NSData * _Nullable data, NSError * _Nullable error))completion;

#pragma mark - 工具方法

/// 检查蓝牙是否可用
- (BOOL)isBluetoothAvailable;

/// 获取当前MTU大小
- (NSInteger)currentMTU;

@end

NS_ASSUME_NONNULL_END
