//
//  ViewController.m
//  Bluetooth
//
//  Created by FumingLeo on 2025/11/28.
//
//  蓝牙手柄交互示例 - 展示如何使用GamepadManager

#import "ViewController.h"
#import "GamepadManager.h"
#import <CoreBluetooth/CoreBluetooth.h>

@interface ViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>

// UI组件
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UIButton *disconnectButton;
@property (nonatomic, strong) UITextField *searchTextField;
@property (nonatomic, strong) UITableView *deviceTableView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *batteryLabel;
@property (nonatomic, strong) UIProgressView *connectionProgressView;

// 数据
@property (nonatomic, strong) GamepadManager *gamepadManager;
@property (nonatomic, strong) NSMutableArray<CBPeripheral *> *discoveredDevices;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *deviceRSSIDict; // 设备RSSI字典
@property (nonatomic, strong, nullable) CBPeripheral *selectedPeripheral;
@property (nonatomic, strong, nullable) NSString *searchKeyword; // 搜索关键词

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"蓝牙手柄管理";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    // 初始化
    self.gamepadManager = [GamepadManager sharedManager];
    self.discoveredDevices = [NSMutableArray array];
    self.deviceRSSIDict = [NSMutableDictionary dictionary];
    self.searchKeyword = nil;
    
    // 设置回调
    [self setupGamepadManagerCallbacks];
    
    // 创建UI
    [self setupUI];
    
    // 更新UI状态
    [self updateUIState];
}

#pragma mark - 设置GamepadManager回调

- (void)setupGamepadManagerCallbacks {
    __weak typeof(self) weakSelf = self;
    
    // 设备发现回调
    self.gamepadManager.discoveryBlock = ^(CBPeripheral *peripheral, NSNumber *RSSI) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleDeviceDiscovered:peripheral RSSI:RSSI];
        });
    };
    
    // 电池电量回调
    self.gamepadManager.batteryBlock = ^(NSInteger batteryLevel) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleBatteryUpdate:batteryLevel];
        });
    };
    
    // 错误回调
    self.gamepadManager.errorBlock = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleError:error];
        });
    };
}

#pragma mark - UI创建

- (void)setupUI {
    // 扫描按钮
    self.scanButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.scanButton setTitle:@"开始扫描" forState:UIControlStateNormal];
    [self.scanButton setTitle:@"停止扫描" forState:UIControlStateSelected];
    self.scanButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [self.scanButton addTarget:self action:@selector(scanButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    self.scanButton.backgroundColor = [UIColor systemBlueColor];
    [self.scanButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.scanButton.layer.cornerRadius = 8;
    
    // 连接按钮
    self.connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.connectButton setTitle:@"连接设备" forState:UIControlStateNormal];
    self.connectButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [self.connectButton addTarget:self action:@selector(connectButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    self.connectButton.backgroundColor = [UIColor systemGreenColor];
    [self.connectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.connectButton.layer.cornerRadius = 8;
    
    // 断开按钮
    self.disconnectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.disconnectButton setTitle:@"断开连接" forState:UIControlStateNormal];
    self.disconnectButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [self.disconnectButton addTarget:self action:@selector(disconnectButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    self.disconnectButton.backgroundColor = [UIColor systemRedColor];
    [self.disconnectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.disconnectButton.layer.cornerRadius = 8;
    self.disconnectButton.enabled = NO;
    
    // 状态标签
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"状态: 未连接";
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.textColor = [UIColor labelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    
    // 电池电量标签
    self.batteryLabel = [[UILabel alloc] init];
    self.batteryLabel.text = @"电池: --";
    self.batteryLabel.font = [UIFont systemFontOfSize:14];
    self.batteryLabel.textColor = [UIColor labelColor];
    self.batteryLabel.textAlignment = NSTextAlignmentCenter;
    
    // 连接进度条
    self.connectionProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.connectionProgressView.hidden = YES;
    
    // 搜索框
    self.searchTextField = [[UITextField alloc] init];
    self.searchTextField.placeholder = @"搜索设备名称（输入后按Return）";
    self.searchTextField.borderStyle = UITextBorderStyleRoundedRect;
    self.searchTextField.font = [UIFont systemFontOfSize:14];
    self.searchTextField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.searchTextField.returnKeyType = UIReturnKeySearch;
    self.searchTextField.delegate = self;
    self.searchTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    
    // 设备列表
    self.deviceTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.deviceTableView.dataSource = self;
    self.deviceTableView.delegate = self;
    self.deviceTableView.rowHeight = 60;
    [self.deviceTableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"DeviceCell"];
    
    // 添加到视图
    [self.view addSubview:self.scanButton];
    [self.view addSubview:self.connectButton];
    [self.view addSubview:self.disconnectButton];
    [self.view addSubview:self.statusLabel];
    [self.view addSubview:self.batteryLabel];
    [self.view addSubview:self.connectionProgressView];
    [self.view addSubview:self.searchTextField];
    [self.view addSubview:self.deviceTableView];
    
    // 设置约束
    [self setupConstraints];
}

- (void)setupConstraints {
    self.scanButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.connectButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.disconnectButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.batteryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.connectionProgressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchTextField.translatesAutoresizingMaskIntoConstraints = NO;
    self.deviceTableView.translatesAutoresizingMaskIntoConstraints = NO;
    
    [NSLayoutConstraint activateConstraints:@[
        // 扫描按钮
        [self.scanButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
        [self.scanButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.scanButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.scanButton.heightAnchor constraintEqualToConstant:44],
        
        // 连接按钮
        [self.connectButton.topAnchor constraintEqualToAnchor:self.scanButton.bottomAnchor constant:15],
        [self.connectButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.connectButton.widthAnchor constraintEqualToConstant:120],
        [self.connectButton.heightAnchor constraintEqualToConstant:44],
        
        // 断开按钮
        [self.disconnectButton.topAnchor constraintEqualToAnchor:self.scanButton.bottomAnchor constant:15],
        [self.disconnectButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.disconnectButton.widthAnchor constraintEqualToConstant:120],
        [self.disconnectButton.heightAnchor constraintEqualToConstant:44],
        
        // 状态标签
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.connectButton.bottomAnchor constant:15],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.statusLabel.heightAnchor constraintEqualToConstant:20],
        
        // 电池标签
        [self.batteryLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:10],
        [self.batteryLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.batteryLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.batteryLabel.heightAnchor constraintEqualToConstant:20],
        
        // 进度条
        [self.connectionProgressView.topAnchor constraintEqualToAnchor:self.batteryLabel.bottomAnchor constant:10],
        [self.connectionProgressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.connectionProgressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.connectionProgressView.heightAnchor constraintEqualToConstant:4],
        
        // 搜索框
        [self.searchTextField.topAnchor constraintEqualToAnchor:self.connectionProgressView.bottomAnchor constant:15],
        [self.searchTextField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.searchTextField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.searchTextField.heightAnchor constraintEqualToConstant:36],
        
        // 设备列表
        [self.deviceTableView.topAnchor constraintEqualToAnchor:self.searchTextField.bottomAnchor constant:10],
        [self.deviceTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.deviceTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.deviceTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

#pragma mark - 按钮事件

- (void)scanButtonTapped:(UIButton *)sender {
    if (sender.isSelected) {
        // 停止扫描
        [self.gamepadManager stopScanning];
        sender.selected = NO;
        NSLog(@"停止扫描");
    } else {
        // 开始扫描
        [self.discoveredDevices removeAllObjects];
        [self.deviceRSSIDict removeAllObjects];
        self.searchKeyword = nil;
        self.searchTextField.text = @"";
        [self.deviceTableView reloadData];
        
        // 检查蓝牙是否可用
        if (![self.gamepadManager isBluetoothAvailable]) {
            [self showAlertWithTitle:@"提示" message:@"蓝牙未开启，请先开启蓝牙"];
            return;
        }
        
        [self.gamepadManager startScanningWithServiceUUIDs:nil]; // nil表示扫描所有设备
        sender.selected = YES;
        NSLog(@"开始扫描");
    }
}

- (void)connectButtonTapped:(UIButton *)sender {
    // 检查是否已选择设备
    if (!self.selectedPeripheral) {
        [self showAlertWithTitle:@"提示" message:@"请先在设备列表中选择一个设备"];
        return;
    }
    
    // 检查蓝牙是否可用
    if (![self.gamepadManager isBluetoothAvailable]) {
        [self showAlertWithTitle:@"提示" message:@"蓝牙未开启，请先开启蓝牙"];
        return;
    }
    
    // 检查当前连接状态
    GamepadConnectionState state = self.gamepadManager.connectionState;
    if (state == GamepadConnectionStateConnecting) {
        [self showAlertWithTitle:@"提示" message:@"正在连接中，请稍候..."];
        return;
    }
    
    if (state == GamepadConnectionStateConnected) {
        [self showAlertWithTitle:@"提示" message:@"设备已连接，请先断开当前连接"];
        return;
    }
    
    if (state == GamepadConnectionStateDisconnecting) {
        [self showAlertWithTitle:@"提示" message:@"正在断开连接，请稍候..."];
        return;
    }
    
    // 显示进度条
    self.connectionProgressView.hidden = NO;
    self.connectionProgressView.progress = 0;
    
    // 连接设备
    __weak typeof(self) weakSelf = self;
    [self.gamepadManager connectPeripheral:self.selectedPeripheral
                                  progress:^(CGFloat progress, NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.connectionProgressView.progress = progress;
            weakSelf.statusLabel.text = [NSString stringWithFormat:@"状态: %@", status];
        });
    }
                                    result:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.connectionProgressView.hidden = YES;
            
            if (success) {
                [weakSelf showAlertWithTitle:@"成功" message:@"设备连接成功"];
                [weakSelf updateUIState];
            } else {
                NSString *message = error ? error.localizedDescription : @"连接失败";
                [weakSelf showAlertWithTitle:@"连接失败" message:message];
                weakSelf.statusLabel.text = @"状态: 连接失败";
            }
        });
    }];
}

- (void)disconnectButtonTapped:(UIButton *)sender {
    [self.gamepadManager disconnect];
    self.selectedPeripheral = nil;
    [self updateUIState];
    self.statusLabel.text = @"状态: 已断开";
    self.batteryLabel.text = @"电池: --";
    NSLog(@"断开连接");
}

#pragma mark - 回调处理

- (void)handleDeviceDiscovered:(CBPeripheral *)peripheral RSSI:(NSNumber *)RSSI {
    // 检查设备是否已存在
    BOOL exists = NO;
    for (CBPeripheral *device in self.discoveredDevices) {
        if ([device.identifier isEqual:peripheral.identifier]) {
            exists = YES;
            break;
        }
    }
    
    if (!exists) {
        [self.discoveredDevices addObject:peripheral];
    }
    
    // 更新RSSI
    self.deviceRSSIDict[peripheral.identifier.UUIDString] = RSSI;
    
    // 刷新列表
    [self.deviceTableView reloadData];
}

- (void)handleBatteryUpdate:(NSInteger)batteryLevel {
    self.batteryLabel.text = [NSString stringWithFormat:@"电池: %ld%%", (long)batteryLevel];
    
    // 根据电量设置颜色
    if (batteryLevel > 50) {
        self.batteryLabel.textColor = [UIColor systemGreenColor];
    } else if (batteryLevel > 20) {
        self.batteryLabel.textColor = [UIColor systemOrangeColor];
    } else {
        self.batteryLabel.textColor = [UIColor systemRedColor];
    }
}

- (void)handleError:(NSError *)error {
    NSString *message = error.localizedDescription ?: @"未知错误";
    [self showAlertWithTitle:@"错误" message:message];
    NSLog(@"错误: %@", error);
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    // 点击Return按钮时执行搜索
    [textField resignFirstResponder];
    
    NSString *keyword = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    if (keyword.length > 0) {
        self.searchKeyword = keyword;
    } else {
        self.searchKeyword = nil;
    }
    
    // 刷新设备列表
    [self.deviceTableView reloadData];
    
    return YES;
}

- (BOOL)textFieldShouldClear:(UITextField *)textField {
    // 清空搜索框时，清除搜索关键词
    self.searchKeyword = nil;
    [self.deviceTableView reloadData];
    return YES;
}

#pragma mark - 过滤设备

- (NSArray<CBPeripheral *> *)filteredDevices {
    if (!self.searchKeyword || self.searchKeyword.length == 0) {
        return self.discoveredDevices;
    }
    
    NSMutableArray<CBPeripheral *> *filtered = [NSMutableArray array];
    NSString *lowercaseKeyword = [self.searchKeyword lowercaseString];
    
    for (CBPeripheral *peripheral in self.discoveredDevices) {
        NSString *deviceName = peripheral.name ?: @"未知设备";
        if ([[deviceName lowercaseString] containsString:lowercaseKeyword]) {
            [filtered addObject:peripheral];
        }
    }
    
    return filtered;
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self filteredDevices].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DeviceCell" forIndexPath:indexPath];
    
    NSArray<CBPeripheral *> *filteredDevices = [self filteredDevices];
    CBPeripheral *peripheral = filteredDevices[indexPath.row];
    NSString *deviceName = peripheral.name ?: @"未知设备";
    NSString *identifier = peripheral.identifier.UUIDString;
    
    // 获取RSSI
    NSNumber *RSSI = self.deviceRSSIDict[identifier];
    NSString *rssiString = RSSI ? [NSString stringWithFormat:@"RSSI: %@", RSSI] : @"";
    
    // 检查是否已连接
    BOOL isConnected = (self.gamepadManager.connectionState == GamepadConnectionStateConnected &&
                       [self.gamepadManager.connectedPeripheral.identifier isEqual:peripheral.identifier]);
    NSString *statusString = isConnected ? @" [已连接]" : @"";
    
    cell.textLabel.text = [NSString stringWithFormat:@"%@%@", deviceName, statusString];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@", identifier, rssiString];
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    
    // 选中状态
    if (self.selectedPeripheral && [peripheral.identifier isEqual:self.selectedPeripheral.identifier]) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSArray<CBPeripheral *> *filteredDevices = [self filteredDevices];
    CBPeripheral *peripheral = filteredDevices[indexPath.row];
    self.selectedPeripheral = peripheral;
    
    // 更新选中状态
    [tableView reloadData];
    
    NSLog(@"选择设备: %@", peripheral.name);
}

#pragma mark - UI状态更新

- (void)updateUIState {
    GamepadConnectionState state = self.gamepadManager.connectionState;
    
    switch (state) {
        case GamepadConnectionStateDisconnected:
            self.statusLabel.text = @"状态: 未连接";
            self.statusLabel.textColor = [UIColor labelColor];
            self.disconnectButton.enabled = NO;
            break;
            
        case GamepadConnectionStateConnecting:
            self.statusLabel.text = @"状态: 连接中...";
            self.statusLabel.textColor = [UIColor systemOrangeColor];
            self.disconnectButton.enabled = NO;
            break;
            
        case GamepadConnectionStateConnected:
            self.statusLabel.text = @"状态: 已连接";
            self.statusLabel.textColor = [UIColor systemGreenColor];
            self.disconnectButton.enabled = YES;
            break;
            
        case GamepadConnectionStateDisconnecting:
            self.statusLabel.text = @"状态: 断开中...";
            self.statusLabel.textColor = [UIColor systemOrangeColor];
            self.disconnectButton.enabled = NO;
            break;
    }
    
    // 刷新设备列表以显示连接状态
    [self.deviceTableView reloadData];
}

#pragma mark - 工具方法

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *action = [UIAlertAction actionWithTitle:@"确定" 
                                                      style:UIAlertActionStyleDefault 
                                                    handler:nil];
    [alert addAction:action];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    // 监听连接状态变化（通过KVO或通知）
    // 这里简化处理，实际应该监听GamepadManager的状态变化
    [self updateUIState];
}

- (void)dealloc {
    // 清理
    self.gamepadManager.discoveryBlock = nil;
    self.gamepadManager.batteryBlock = nil;
    self.gamepadManager.errorBlock = nil;
}

@end
