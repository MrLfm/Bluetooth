//
//  GamepadManager.m
//  Bluetooth
//
//  Created by FumingLeo on 2025/11/28.
//
//  蓝牙手柄管理器实现 - 示例代码
//  展示了如何正确处理iOS蓝牙开发中的常见问题

#import "GamepadManager.h"
#import <CoreBluetooth/CoreBluetooth.h>

// 日志宏
#ifdef DEBUG
#define GamepadLog(fmt, ...) NSLog((@"[GamepadManager] %s [%d行] " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__)
#else
#define GamepadLog(...)
#endif

// 自定义错误代码
typedef NS_ENUM(NSInteger, GamepadManagerErrorCode) {
    GamepadManagerErrorUnsupported = 1001,
    GamepadManagerErrorUnauthorized = 1002,
    GamepadManagerErrorPoweredOff = 1003,
    GamepadManagerErrorConnectionTimeout = 1004
};

// 默认Service UUID（示例，实际使用时替换为你的Service UUID）
static NSString * const kDefaultServiceUUID = @"0000FFE0-0000-1000-8000-00805F9B34FB";
static NSString * const kBatteryCharacteristicUUID = @"2A19";

@interface GamepadManager () <CBCentralManagerDelegate, CBPeripheralDelegate>

// CoreBluetooth
@property (nonatomic, strong) CBCentralManager *centralManager;
@property (nonatomic, strong, nullable) CBPeripheral *connectedPeripheral;
@property (nonatomic, strong, nullable) CBCharacteristic *batteryCharacteristic;

// 连接管理
@property (nonatomic, assign) GamepadConnectionState connectionState;
@property (nonatomic, strong, nullable) NSTimer *connectionTimeoutTimer;
@property (nonatomic, copy, nullable) GamepadConnectionProgressBlock connectionProgressBlock;
@property (nonatomic, copy, nullable) GamepadConnectionResultBlock connectionResultBlock;

// 数据写入队列
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *writeQueue;
@property (nonatomic, assign) BOOL isWriting;
@property (nonatomic, strong) dispatch_queue_t writeQueueSerial; // 串行队列用于写入

// 已发现的服务集合（线程安全）
@property (nonatomic, strong) NSMutableSet<CBUUID *> *discoveredServices;

@end

@implementation GamepadManager

#pragma mark - 初始化

+ (instancetype)sharedManager {
    static GamepadManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GamepadManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 初始化CoreBluetooth（使用主队列确保回调在主线程）
        _centralManager = [[CBCentralManager alloc] initWithDelegate:self 
                                                               queue:dispatch_get_main_queue()];
        
        // 初始化连接状态
        _connectionState = GamepadConnectionStateDisconnected;
        _connectionTimeout = 10.0; // 默认10秒超时
        
        // 初始化写入队列
        _writeQueue = [NSMutableArray array];
        _isWriting = NO;
        _writeQueueSerial = dispatch_queue_create("com.gamesir.writeQueue", DISPATCH_QUEUE_SERIAL);
        
        // 初始化已发现服务集合
        _discoveredServices = [NSMutableSet set];
        
        // 监听应用生命周期
        [self setupApplicationNotifications];
    }
    return self;
}

- (void)setupApplicationNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackground:)
                                                 name:NSExtensionHostDidEnterBackgroundNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground:)
                                                 name:NSExtensionHostWillEnterForegroundNotification
                                               object:nil];
}

#pragma mark - 公共方法

- (void)startScanningWithServiceUUIDs:(nullable NSArray<CBUUID *> *)serviceUUIDs {
    // 检查蓝牙状态
    if (self.centralManager.state != CBManagerStatePoweredOn) {
        GamepadLog(@"⚠️ 蓝牙未开启，当前状态: %ld", (long)self.centralManager.state);
        if (self.errorBlock) {
            NSError *error = [NSError errorWithDomain:@"GamepadManager" 
                                                   code:-1 
                                               userInfo:@{NSLocalizedDescriptionKey: @"蓝牙未开启"}];
            self.errorBlock(error);
        }
        return;
    }
    
    // 如果已经在扫描，先停止
    if (self.centralManager.isScanning) {
        [self stopScanning];
    }
    
    // 构建扫描选项
    NSDictionary *options = @{
        CBCentralManagerScanOptionAllowDuplicatesKey: @NO // 不允许重复，减少回调
    };
    
    GamepadLog(@"开始扫描设备，ServiceUUIDs: %@", serviceUUIDs);
    [self.centralManager scanForPeripheralsWithServices:serviceUUIDs options:options];
}

- (void)stopScanning {
    if (self.centralManager.isScanning) {
        GamepadLog(@"停止扫描");
        [self.centralManager stopScan];
    }
}

- (void)connectPeripheral:(CBPeripheral *)peripheral
                 progress:(nullable GamepadConnectionProgressBlock)progressBlock
                   result:(nullable GamepadConnectionResultBlock)resultBlock {
    // 检查当前状态
    if (self.connectionState == GamepadConnectionStateConnecting ||
        self.connectionState == GamepadConnectionStateConnected) {
        GamepadLog(@"⚠️ 已有连接在进行中，当前状态: %ld", (long)self.connectionState);
        if (resultBlock) {
            NSError *error = [NSError errorWithDomain:@"GamepadManager" 
                                                   code:-2 
                                               userInfo:@{NSLocalizedDescriptionKey: @"已有连接在进行中"}];
            resultBlock(NO, error);
        }
        return;
    }
    
    // 更新状态
    self.connectionState = GamepadConnectionStateConnecting;
    self.connectionProgressBlock = progressBlock;
    self.connectionResultBlock = resultBlock;
    
    // 更新进度
    if (progressBlock) {
        progressBlock(0.2, @"正在连接设备...");
    }
    
    // iOS 17+ 需要先停止扫描
    if (@available(iOS 17.0, *)) {
        [self stopScanning];
        // 等待一小段时间确保扫描完全停止
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), 
                      dispatch_get_main_queue(), ^{
            [self doConnectPeripheral:peripheral];
        });
    } else {
        [self doConnectPeripheral:peripheral];
    }
    
    // 启动连接超时
    [self startConnectionTimeout];
}

- (void)doConnectPeripheral:(CBPeripheral *)peripheral {
    self.connectedPeripheral = peripheral;
    peripheral.delegate = self;
    
    GamepadLog(@"连接设备: %@", peripheral.name);
    [self.centralManager connectPeripheral:peripheral options:nil];
}

- (void)disconnect {
    if (self.connectionState == GamepadConnectionStateDisconnected) {
        return;
    }
    
    self.connectionState = GamepadConnectionStateDisconnecting;
    
    // 取消连接超时
    [self cancelConnectionTimeout];
    
    if (self.connectedPeripheral) {
        [self.centralManager cancelPeripheralConnection:self.connectedPeripheral];
    }
    
    [self cleanupConnection];
}

- (void)writeData:(NSData *)data
 toCharacteristic:(CBCharacteristic *)characteristic
       completion:(nullable void(^)(NSError * _Nullable error))completion {
    if (!data || !characteristic) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"GamepadManager" 
                                                 code:-3 
                                             userInfo:@{NSLocalizedDescriptionKey: @"数据或特征值为空"}];
            completion(error);
        }
        return;
    }
    
    // 检查连接状态
    if (self.connectionState != GamepadConnectionStateConnected ||
        !self.connectedPeripheral ||
        self.connectedPeripheral.state != CBPeripheralStateConnected) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"GamepadManager" 
                                                 code:-4 
                                             userInfo:@{NSLocalizedDescriptionKey: @"设备未连接"}];
            completion(error);
        }
        return;
    }
    
    // 添加到写入队列（带频率限制）
    id completionValue = completion ? (id)completion : [NSNull null];
    NSDictionary *item = @{
        @"data": data,
        @"characteristic": characteristic,
        @"completion": completionValue
    };
    
    dispatch_async(self.writeQueueSerial, ^{
        [self.writeQueue addObject:item];
        [self processWriteQueue];
    });
}

- (void)readDataFromCharacteristic:(CBCharacteristic *)characteristic
                         completion:(nullable void(^)(NSData * _Nullable data, NSError * _Nullable error))completion {
    if (!characteristic) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"GamepadManager" 
                                                 code:-3 
                                             userInfo:@{NSLocalizedDescriptionKey: @"特征值为空"}];
            completion(nil, error);
        }
        return;
    }
    
    // 检查连接状态
    if (self.connectionState != GamepadConnectionStateConnected ||
        !self.connectedPeripheral ||
        self.connectedPeripheral.state != CBPeripheralStateConnected) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"GamepadManager" 
                                                 code:-4 
                                             userInfo:@{NSLocalizedDescriptionKey: @"设备未连接"}];
            completion(nil, error);
        }
        return;
    }
    
    // 确保在主线程执行
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self readDataFromCharacteristic:characteristic completion:completion];
        });
        return;
    }
    
    [self.connectedPeripheral readValueForCharacteristic:characteristic];
    // 注意：实际应该使用delegate回调返回结果，这里简化处理
}

- (BOOL)isBluetoothAvailable {
    return self.centralManager.state == CBManagerStatePoweredOn;
}

- (NSInteger)currentMTU {
    if (self.connectedPeripheral &&
        [self.connectedPeripheral respondsToSelector:@selector(maximumWriteValueLengthForType:)]) {
        return [self.connectedPeripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse];
    }
    return 20; // BLE默认MTU
}

#pragma mark - 连接超时管理

- (void)startConnectionTimeout {
    [self cancelConnectionTimeout];
    
    self.connectionTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:self.connectionTimeout
                                                                    target:self
                                                                  selector:@selector(handleConnectionTimeout)
                                                                  userInfo:nil
                                                                   repeats:NO];
}

- (void)cancelConnectionTimeout {
    if (self.connectionTimeoutTimer) {
        [self.connectionTimeoutTimer invalidate];
        self.connectionTimeoutTimer = nil;
    }
}

- (void)handleConnectionTimeout {
    GamepadLog(@"❌ 连接超时");
    
    if (self.connectionState == GamepadConnectionStateConnecting) {
        [self disconnect];
        
        if (self.connectionResultBlock) {
            NSError *error = [NSError errorWithDomain:@"GamepadManager" 
                                                 code:GamepadManagerErrorConnectionTimeout 
                                             userInfo:@{NSLocalizedDescriptionKey: @"连接超时"}];
            self.connectionResultBlock(NO, error);
            self.connectionResultBlock = nil;
        }
    }
}

#pragma mark - 写入队列处理

- (void)processWriteQueue {
    if (self.isWriting || self.writeQueue.count == 0) {
        return;
    }
    
    // 检查连接状态
    if (self.connectionState != GamepadConnectionStateConnected ||
        !self.connectedPeripheral ||
        self.connectedPeripheral.state != CBPeripheralStateConnected) {
        // 清空队列
        [self.writeQueue removeAllObjects];
        return;
    }
    
    self.isWriting = YES;
    NSDictionary *item = self.writeQueue.firstObject;
    [self.writeQueue removeObjectAtIndex:0];
    
    NSData *data = item[@"data"];
    CBCharacteristic *characteristic = item[@"characteristic"];
    void(^completion)(NSError *) = item[@"completion"];
    
    if ([completion isKindOfClass:[NSNull class]]) {
        completion = nil;
    }
    
    // 确保在主线程执行写入
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.connectedPeripheral && 
            self.connectedPeripheral.state == CBPeripheralStateConnected) {
            [self.connectedPeripheral writeValue:data 
                                forCharacteristic:characteristic 
                                             type:CBCharacteristicWriteWithoutResponse];
            
            if (completion) {
                completion(nil);
            }
        } else {
            if (completion) {
                NSError *error = [NSError errorWithDomain:@"GamepadManager" 
                                                     code:-4 
                                                 userInfo:@{NSLocalizedDescriptionKey: @"设备已断开"}];
                completion(error);
            }
        }
        
        // 限制写入频率：每100ms一次
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), 
                      self.writeQueueSerial, ^{
            self.isWriting = NO;
            [self processWriteQueue];
        });
    });
}

#pragma mark - 清理

- (void)cleanupConnection {
    // 取消连接超时
    [self cancelConnectionTimeout];
    
    // 清理peripheral delegate
    if (self.connectedPeripheral) {
        self.connectedPeripheral.delegate = nil;
    }
    self.connectedPeripheral = nil;
    
    // 清理特征值
    self.batteryCharacteristic = nil;
    
    // 清空写入队列
    dispatch_async(self.writeQueueSerial, ^{
        [self.writeQueue removeAllObjects];
        self.isWriting = NO;
    });
    
    // 重置已发现服务集合
    [self.discoveredServices removeAllObjects];
    
    // 更新状态
    self.connectionState = GamepadConnectionStateDisconnected;
    
    // 清理回调
    self.connectionProgressBlock = nil;
    self.connectionResultBlock = nil;
}

#pragma mark - CBCentralManagerDelegate

// 蓝牙状态更新
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    GamepadLog(@"蓝牙状态更新: %ld", (long)central.state);
    
    switch (central.state) {
        case CBManagerStateUnknown:
            GamepadLog(@"蓝牙状态未知");
            break;
        case CBManagerStateResetting:
            GamepadLog(@"蓝牙重置中");
            break;
        case CBManagerStateUnsupported:
            GamepadLog(@"设备不支持蓝牙");
            if (self.errorBlock) {
                NSError *error = [NSError errorWithDomain:@"GamepadManager" 
                                                     code:GamepadManagerErrorUnsupported 
                                                 userInfo:@{NSLocalizedDescriptionKey: @"设备不支持蓝牙"}];
                self.errorBlock(error);
            }
            break;
        case CBManagerStateUnauthorized:
            GamepadLog(@"蓝牙未授权");
            if (self.errorBlock) {
                NSError *error = [NSError errorWithDomain:@"GamepadManager" 
                                                     code:GamepadManagerErrorUnauthorized 
                                                 userInfo:@{NSLocalizedDescriptionKey: @"蓝牙未授权，请在设置中开启"}];
                self.errorBlock(error);
            }
            break;
        case CBManagerStatePoweredOff:
            GamepadLog(@"蓝牙已关闭");
            if (self.errorBlock) {
                NSError *error = [NSError errorWithDomain:@"GamepadManager" 
                                                     code:GamepadManagerErrorPoweredOff 
                                                 userInfo:@{NSLocalizedDescriptionKey: @"蓝牙已关闭，请开启蓝牙"}];
                self.errorBlock(error);
            }
            break;
        case CBManagerStatePoweredOn:
            GamepadLog(@"蓝牙已开启");
            break;
        default:
            break;
    }
}

// 发现设备
- (void)centralManager:(CBCentralManager *)central 
 didDiscoverPeripheral:(CBPeripheral *)peripheral 
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData 
                  RSSI:(NSNumber *)RSSI {
    // 确保在主线程（虽然已经在主队列，但双重保险）
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self centralManager:central 
          didDiscoverPeripheral:peripheral 
              advertisementData:advertisementData 
                           RSSI:RSSI];
        });
        return;
    }
    
    GamepadLog(@"发现设备: %@, RSSI: %@", peripheral.name, RSSI);
    
    // 通知外部
    if (self.discoveryBlock) {
        self.discoveryBlock(peripheral, RSSI);
    }
}

// 连接成功
- (void)centralManager:(CBCentralManager *)central 
  didConnectPeripheral:(CBPeripheral *)peripheral {
    GamepadLog(@"✅ 设备连接成功: %@", peripheral.name);
    
    // 取消连接超时
    [self cancelConnectionTimeout];
    
    // 更新进度
    if (self.connectionProgressBlock) {
        self.connectionProgressBlock(0.5, @"正在发现服务...");
    }
    
    // 发现服务
    [self.discoveredServices removeAllObjects];
    [peripheral discoverServices:nil];
}

// 连接失败
- (void)centralManager:(CBCentralManager *)central 
didFailToConnectPeripheral:(CBPeripheral *)peripheral 
                  error:(nullable NSError *)error {
    GamepadLog(@"❌ 设备连接失败: %@, 错误: %@", peripheral.name, error.localizedDescription);
    
    [self cancelConnectionTimeout];
    [self cleanupConnection];
    
    if (self.connectionResultBlock) {
        self.connectionResultBlock(NO, error);
        self.connectionResultBlock = nil;
    }
}

// 断开连接
- (void)centralManager:(CBCentralManager *)central 
didDisconnectPeripheral:(CBPeripheral *)peripheral 
                  error:(nullable NSError *)error {
    GamepadLog(@"设备断开连接: %@, 错误: %@", peripheral.name, error.localizedDescription);
    
    [self cleanupConnection];
    
    if (error && self.errorBlock) {
        self.errorBlock(error);
    }
}

#pragma mark - CBPeripheralDelegate

// 发现服务
- (void)peripheral:(CBPeripheral *)peripheral 
didDiscoverServices:(nullable NSError *)error {
    // ✅ 确保在主线程
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self peripheral:peripheral didDiscoverServices:error];
        });
        return;
    }
    
    // ✅ 检查错误
    if (error) {
        GamepadLog(@"❌ 发现服务失败: %@", error.localizedDescription);
        [self cleanupConnection];
        if (self.connectionResultBlock) {
            self.connectionResultBlock(NO, error);
            self.connectionResultBlock = nil;
        }
        return;
    }
    
    // ✅ 检查peripheral状态
    if (peripheral.state != CBPeripheralStateConnected) {
        GamepadLog(@"⚠️ Peripheral未连接，状态: %ld", (long)peripheral.state);
        return;
    }
    
    // ✅ 检查数据有效性
    if (!peripheral.services || peripheral.services.count == 0) {
        GamepadLog(@"⚠️ 未发现任何服务");
        return;
    }
    
    // 更新进度
    if (self.connectionProgressBlock) {
        self.connectionProgressBlock(0.7, @"正在发现特征值...");
    }
    
    // 发现所有服务的特征值
    for (CBService *service in peripheral.services) {
        [peripheral discoverCharacteristics:nil forService:service];
    }
}

// 发现特征值
- (void)peripheral:(CBPeripheral *)peripheral 
didDiscoverCharacteristicsForService:(CBService *)service 
             error:(nullable NSError *)error {
    // ✅ 确保在主线程
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self peripheral:peripheral didDiscoverCharacteristicsForService:service error:error];
        });
        return;
    }
    
    // ✅ 检查错误
    if (error) {
        GamepadLog(@"❌ 发现特征值失败: %@", error.localizedDescription);
        return;
    }
    
    // ✅ 检查peripheral状态
    if (peripheral.state != CBPeripheralStateConnected) {
        GamepadLog(@"⚠️ Peripheral未连接，取消处理特征");
        return;
    }
    
    // ✅ 防止重复处理（使用线程安全的集合）
    @synchronized(self.discoveredServices) {
        if ([self.discoveredServices containsObject:service.UUID]) {
            return;
        }
        [self.discoveredServices addObject:service.UUID];
    }
    
    GamepadLog(@"发现服务: %@, 特征值数量: %lu", service.UUID.UUIDString, (unsigned long)service.characteristics.count);
    
    // 处理特征值
    for (CBCharacteristic *characteristic in service.characteristics) {
        NSString *uuidString = characteristic.UUID.UUIDString;
        GamepadLog(@"发现特征值: %@", uuidString);
        
        // 电池电量特征值
        if ([uuidString.lowercaseString isEqualToString:kBatteryCharacteristicUUID.lowercaseString]) {
            self.batteryCharacteristic = characteristic;
            // 读取电池电量
            [peripheral readValueForCharacteristic:characteristic];
        }
        
        // 开启通知
        if (characteristic.properties & CBCharacteristicPropertyNotify) {
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
        }
    }
    
    // 检查是否所有服务都已处理完成
    if (self.discoveredServices.count == peripheral.services.count) {
        // 连接完成
        self.connectionState = GamepadConnectionStateConnected;
        
        if (self.connectionProgressBlock) {
            self.connectionProgressBlock(1.0, @"连接成功");
        }
        
        if (self.connectionResultBlock) {
            self.connectionResultBlock(YES, nil);
            self.connectionResultBlock = nil;
        }
    }
}

// 特征值更新（通知或读取）
- (void)peripheral:(CBPeripheral *)peripheral 
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic 
             error:(nullable NSError *)error {
    // ✅ 确保在主线程
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self peripheral:peripheral didUpdateValueForCharacteristic:characteristic error:error];
        });
        return;
    }
    
    // ✅ 检查错误
    if (error) {
        GamepadLog(@"❌ 读取特征值失败: %@", error.localizedDescription);
        return;
    }
    
    // ✅ 检查数据有效性
    if (!characteristic.value || characteristic.value.length == 0) {
        GamepadLog(@"⚠️ 特征值为空");
        return;
    }
    
    NSString *uuidString = characteristic.UUID.UUIDString;
    
    // 处理电池电量
    if ([uuidString.lowercaseString isEqualToString:kBatteryCharacteristicUUID.lowercaseString]) {
        NSInteger batteryLevel = 0;
        if (characteristic.value.length > 0) {
            const uint8_t *bytes = characteristic.value.bytes;
            batteryLevel = bytes[0];
        }
        
        GamepadLog(@"电池电量: %ld%%", (long)batteryLevel);
        
        if (self.batteryBlock) {
            self.batteryBlock(batteryLevel);
        }
    }
}

// 写入完成
- (void)peripheral:(CBPeripheral *)peripheral 
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic 
             error:(nullable NSError *)error {
    // ✅ 确保在主线程
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self peripheral:peripheral didWriteValueForCharacteristic:characteristic error:error];
        });
        return;
    }
    
    if (error) {
        GamepadLog(@"❌ 写入特征值失败: %@", error.localizedDescription);
    } else {
        GamepadLog(@"✅ 写入特征值成功");
    }
}

// 通知状态更新
- (void)peripheral:(CBPeripheral *)peripheral 
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic 
             error:(nullable NSError *)error {
    // ✅ 确保在主线程
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self peripheral:peripheral didUpdateNotificationStateForCharacteristic:characteristic error:error];
        });
        return;
    }
    
    if (error) {
        GamepadLog(@"❌ 开启通知失败: %@", error.localizedDescription);
    } else {
        GamepadLog(@"✅ 通知已成功设置: %@", characteristic.UUID.UUIDString);
    }
}

#pragma mark - 应用生命周期

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    GamepadLog(@"应用进入后台");
    
    // 后台扫描必须使用特定的serviceUUID
    CBUUID *serviceUUID = [CBUUID UUIDWithString:kDefaultServiceUUID];
    [self startScanningWithServiceUUIDs:@[serviceUUID]];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    GamepadLog(@"应用进入前台");
    
    // 恢复完整扫描（如果需要）
    // [self startScanningWithServiceUUIDs:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self cancelConnectionTimeout];
    [self cleanupConnection];
}

@end
