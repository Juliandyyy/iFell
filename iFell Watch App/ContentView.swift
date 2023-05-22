import SwiftUI
import HealthKit
import CoreMotion
import WatchKit
import AVFoundation

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        
        scanner.scanLocation = 1 // Skip the '#' character
        scanner.scanHexInt64(&rgbValue)
        
        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0
        
        self.init(red: red, green: green, blue: blue)
    }
}

extension CMMotionManager {
    private struct AssociatedKeys {
        static var fallDetectedKey = "fallDetected"
    }
    
    var fallDetected: (() -> Void)? {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.fallDetectedKey) as? () -> Void
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.fallDetectedKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

class MotionManager {
    let motionManager = CMMotionManager()
    var shakeDetected: (() -> Void)?
    var isShakeDetected = false // Track if a shake has already been detected
    
    func startDeviceMotionUpdates() {
        motionManager.accelerometerUpdateInterval = 1.0 / 60.0
        
        motionManager.startAccelerometerUpdates(to: .main) { [self] accelerometerData, error in
            guard let accelerometerData = accelerometerData else {
                return
            }
            
            let acceleration = accelerometerData.acceleration
            let magnitude = sqrt(pow(acceleration.x, 2) + pow(acceleration.y, 2) + pow(acceleration.z, 2))/2
            
            if magnitude > 10.0 {
                print("Shake Detected")
                isShakeDetected = true // Set the flag to true to prevent subsequent shake detections
                self.shakeDetected?()
            } else {
                print("No Shake")
            }
        }
    }
    func stopDeviceMotionUpdates() {
        motionManager.stopAccelerometerUpdates()
    }
}

struct ContentView: View {
    @State private var remainingTime: TimeInterval = 5
    @State private var heartRate: Double = 0
    @State private var isTimerRunning = true
    @State private var isShowingSafePage = false
    @State private var isShowingDangerPage = false
    @State private var isFallDetected = false
    private let duration: TimeInterval = 120
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    
    private let healthStore = HKHealthStore()
    private let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
    
    private let motionManager = MotionManager()
    private let fallDetectionThreshold: Double = 0.5
    
    var body: some View {
        ZStack {
            Color(hex: "#1F1E1E") // Set the background color to dark gray
                .edgesIgnoringSafeArea(.all)
            
            VStack(alignment: .center) {
                Spacer()
                Text("Are you okay?")
                    .font(.system(size: 17, weight: .bold)) // Set the text font to semibold
                    .foregroundColor(.white)
                    .padding(.top)
                
                TimerView(remainingTime: remainingTime, size: 130, heartRate: heartRate)
                    .frame(width: 200, height: 140)
                    .padding(.init(top: 3, leading: 0, bottom: 0, trailing: 0))
                
                Button(action: {
                    isTimerRunning.toggle()
                    if isTimerRunning {
                        startTimer()
                    } else {
                        stopTimer()
                    }
                }) {
                    Text(isTimerRunning ? "I'm Okay" : "Start")
                        .font(.system(size: 17, weight: .bold))
                }
                .frame(width: 150, height: 40)
                .foregroundColor(.white)
                .background(Color.blue)
                .cornerRadius(25)
                .padding(.init(top: -10, leading: 20, bottom: 0, trailing: 20))
            }
            .padding()
        }
        .onAppear {
#if targetEnvironment(simulator)
            // Running in simulator, skip HealthKit access
#else
            startShakeDetection()
            authorizeHealthKit()
#endif
        }
        .onReceive(timer) { _ in
            if isFallDetected{
                updateTimer()
                keepScreenAwake()
            }
        }
        .sheet(isPresented: $isShowingSafePage, content: { SafePageView() })
        .sheet(isPresented: $isShowingDangerPage, content: { DangerPageView() })
    }
    
    //Ring Alert for User
    func startRinging() {
        let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: Bundle.main.path(forResource: "alarm", ofType: "mp3")!))
        player?.numberOfLoops = 10
        player?.volume = 1.0
        player?.play()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            player?.stop()
        }
    }
    
    
    func startTimer() {
        isTimerRunning = true
        motionManager.stopDeviceMotionUpdates()
    }
    
    func stopTimer() {
        isTimerRunning = false
        isShowingSafePage = true
    }
    
    func updateTimer() {
        guard isTimerRunning else {
            return
        }
        
        remainingTime -= 0.1
        
        if remainingTime <= 0 {
            timer.upstream.connect().cancel()
            showAlert()
            resetScreenAwake()
        }
    }
    
    func showAlert() {
        isShowingDangerPage = true
    }
    
    func checkAuthorizationStatus() {
        let authorizationStatus = healthStore.authorizationStatus(for: heartRateType)
        
        switch authorizationStatus {
        case .notDetermined:
            print("Authorization status: Not determined")
        case .sharingDenied:
            print("Authorization status: Sharing denied")
        case .sharingAuthorized:
            print("Authorization status: Sharing authorized")
        @unknown default:
            print("Authorization status: Default case")
        }
    }
    //Authorization to Access Heart Rate Data
    func authorizeHealthKit() {
        let readTypes: Set<HKObjectType> = [heartRateType]
        
        healthStore.requestAuthorization(toShare: nil, read: readTypes) { success, error in
            if let error = error {
                print("Error requesting HealthKit authorization: \(error.localizedDescription)")
            }
            if success {
                startHeartRateQuery()
            }
            checkAuthorizationStatus()
        }
    }
    
    //Read Heart Rate
    func startHeartRateQuery() {
        let heartRateQuery = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: nil,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { query, samples, deletedObjects, anchor, error in
            guard let samples = samples as? [HKQuantitySample], let sample = samples.last else {
                return
            }
            
            DispatchQueue.main.async {
                let heartRateUnit = HKUnit(from: "count/min")
                self.heartRate = sample.quantity.doubleValue(for: heartRateUnit)
            }
        }
        
        heartRateQuery.updateHandler = { query, samples, deletedObjects, anchor, error in
            guard let samples = samples as? [HKQuantitySample], let sample = samples.last else {
                return
            }
            
            DispatchQueue.main.async {
                let heartRateUnit = HKUnit(from: "count/min")
                self.heartRate = sample.quantity.doubleValue(for: heartRateUnit)
            }
        }
        
        healthStore.execute(heartRateQuery)
    }
    
    
    
    
    func startShakeDetection() {
        motionManager.startDeviceMotionUpdates()
        motionManager.shakeDetected = { [self] in
            self.isFallDetected = true
            startTimer()
            startRinging()
//            openApp()
        }
    }
    
    //ON GOING Auto Open
//    func openApp() {
//            guard let appURL = URL(string: "myapp://") else {
//                return
//            }
//
//            WKExtension.shared().openSystemURL(appURL)
//        }
//
    func keepScreenAwake() {
        WKExtension.shared().isAutorotating = true
    }
    func resetScreenAwake() {
        WKExtension.shared().isAutorotating = false
    }
}

struct TimerView: View {
    var remainingTime: TimeInterval
    var size: CGFloat
    var heartRate: Double
    
    var minutes: Int {
        let totalSeconds = Int(remainingTime.rounded())
        return totalSeconds / 60
    }
    
    var seconds: Int {
        let totalSeconds = Int(remainingTime.rounded())
        return totalSeconds % 60
    }
    
    var formattedHeartRate: String {
        String(format: "%.0f", heartRate)
    }
    
    var body: some View {
        VStack {
            ZStack {
                
                Circle()
                    .trim(from: 0, to: 9.0/12.0)
                    .stroke(style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                    .opacity(0.3)
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: CGFloat((9.0/12.0) - (remainingTime / 120)))
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [Color(hex: "#EEF1E6"),Color(hex: "#2094FA")]),
                            startPoint: .bottomTrailing,
                            endPoint: .topLeading),
                        style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .animation(.linear(duration: 0.1))

                VStack {
                    Text("\(formattedHeartRate) bpm")
                        .font(.system(size: size * 0.14))
                        .foregroundColor(Color(hex: "#F9665E"))
                        .padding(.init(top: 30, leading: 0, bottom: 10, trailing: 0))
                    Text(String(format: "%02d:%02d", minutes, seconds))
                        .font(.system(size: size * 0.2))
                        .bold()
                        .padding(.init(top: 0, leading: 0, bottom: 20, trailing: 0))
                }
            }
            .frame(width: size, height: size)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

struct SafePageView: View {
    var body: some View {
        VStack(alignment: .center) {
            Text("Thank Goodness")
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
            Text("You're Safe")
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
            
            Button(action: {
                exit(0) // Exit the app
            }) {
                Text("Close App")
                    .font(.system(size: 17, weight: .bold))
            }
            .frame(width: 150, height: 40)
            .foregroundColor(.white)
            .background(Color.red)
            .cornerRadius(25)
            .padding(.top, 20)
        }
    }
}


//If No Answer on the timer
struct DangerPageView: View {
    @State private var shouldNavigate = false
    let phoneNumber = "0123456789" // Replace with the desired phone number
    
    var body: some View {
        NavigationView {
            VStack(alignment: .center) {
                Text("Sending help")
                    .font(.system(size: 25, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 50)
                Spacer(minLength: 60)
                Button(action: makePhoneCall){
                    Text("Call for help")
                        .font(.system(size: 17, weight: .bold))
                }
                .frame(width: 150, height: 40)
                .foregroundColor(.white)
                .background(Color.blue)
                .cornerRadius(25)
                .padding(.top, 20)
                
                NavigationLink(
                    destination: OtherUserView(),
                    isActive: $shouldNavigate,
                    label: {
                        EmptyView()
                    })
                .hidden()
            }
            .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            shouldNavigate = true
                        }
                    }
        }
    }
    func makePhoneCall() {
        let phoneURLString = "tel://\(phoneNumber)"
        guard let phoneURL = URL(string: phoneURLString) else {
            return
        }
        
        WKExtension.shared().openSystemURL(phoneURL)
    }
}


// Other User View
struct OtherUserView: View {
    @State private var heartRate: Double = 0
    let deviceName = WKInterfaceDevice.current().name

    
    private let healthStore = HKHealthStore()
    private let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
    
    var body: some View {
        VStack(alignment: .center){
            Text("\(deviceName)")
                .font(.system(size: 20, weight: .bold))
                .padding(.top, 20)
            Text("need your help!")
                .font(.system(size: 20, weight: .bold))
                .padding(.bottom, 20)
            //Hide Back button
            Divider()
            HeartRateView(size: 200, heartRate: heartRate)
        }
        .navigationBarBackButtonHidden(true)
        .onAppear{
            startRinging()
            authorizeHealthKit()
        }
    }
    
    //Ring Alert to Other User
    func startRinging() {
                let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: Bundle.main.path(forResource: "alarm", ofType: "mp3")!))
                        player?.numberOfLoops = 40
                        player?.play()
        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                            player?.stop()
                        }
    }
    
    func checkAuthorizationStatus() {
        let authorizationStatus = healthStore.authorizationStatus(for: heartRateType)
        
        switch authorizationStatus {
        case .notDetermined:
            print("Authorization status: Not determined")
        case .sharingDenied:
            print("Authorization status: Sharing denied")
        case .sharingAuthorized:
            print("Authorization status: Sharing authorized")
        @unknown default:
            print("Authorization status: Default case")
        }
    }
    func authorizeHealthKit() {
        let readTypes: Set<HKObjectType> = [heartRateType]
        
        healthStore.requestAuthorization(toShare: nil, read: readTypes) { success, error in
            if let error = error {
                print("Error requesting HealthKit authorization: \(error.localizedDescription)")
            }
            if success {
                startHeartRateQuery()
            }
            checkAuthorizationStatus()
        }
    }
    
    func startHeartRateQuery() {
        let heartRateQuery = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: nil,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { query, samples, deletedObjects, anchor, error in
            guard let samples = samples as? [HKQuantitySample], let sample = samples.last else {
                return
            }
            
            DispatchQueue.main.async {
                let heartRateUnit = HKUnit(from: "count/min")
                self.heartRate = sample.quantity.doubleValue(for: heartRateUnit)
            }
        }
        
        heartRateQuery.updateHandler = { query, samples, deletedObjects, anchor, error in
            guard let samples = samples as? [HKQuantitySample], let sample = samples.last else {
                return
            }
            
            DispatchQueue.main.async {
                let heartRateUnit = HKUnit(from: "count/min")
                self.heartRate = sample.quantity.doubleValue(for: heartRateUnit)
            }
        }
        
        healthStore.execute(heartRateQuery)
    }
    
    
}

struct HeartRateView: View {
    var size: CGFloat
    var heartRate: Double
    
    var formattedHeartRate: String {
        String(format: "%.0f", heartRate)
    }
    
    var body: some View {
        HStack(alignment: .center) {
            Text("\(formattedHeartRate)")
                .font(.system(size: size * 0.4))
                .foregroundColor(Color(hex: "#F9665E"))
                .padding(.init(top: 10, leading: 0, bottom: 20, trailing: 0))
            Text(" bpm")
                .font(.system(size: size * 0.2))
                .foregroundColor(Color(hex: "#F9665E"))
                .padding(.init(top: 10, leading: 0, bottom: 20, trailing: 0))
        }
    }
}
