//
//  Sentry.swift
//  SentrySwift
//
//  Created by Josh Holtz on 12/16/15.
//
//

import Foundation
#if os(iOS)
    import UIKit
#endif
import KSCrash

// This is declared here to keep namespace compatibility with objc
@objc public enum SentryLog: Int, CustomStringConvertible {
    case None, Error, Debug
    
    public var description: String {
        switch self {
        case .None: return ""
        case .Error: return "Error"
        case .Debug: return "Debug"
        }
    }
    
    internal func log(_ message: String) {
        guard rawValue <= SentryClient.logLevel.rawValue else { return }
        print("SentrySwift - \(description):: \(message)")
    }
}

#if swift(>=3.0)
    public typealias AnyType = Any
#else
    public typealias AnyType = AnyObject
    internal typealias Error = ErrorType
    internal typealias ProcessInfo = NSProcessInfo
    internal typealias JSONSerialization = NSJSONSerialization
    internal typealias Bundle = NSBundle
    internal typealias URLQueryItem = NSURLQueryItem
#endif

internal enum SentryError: Error {
    case InvalidDSN
}

#if os(iOS)
    @objc public protocol SentryClientUserFeedbackDelegate {
        func userFeedbackReady()
        func userFeedbackSent()
    }
#endif

@objc public class SentryClient: NSObject, EventProperties {
    
    // MARK: - Static Attributes
    
    public static var shared: SentryClient?
    public static var logLevel: SentryLog = .None
    
    public static var versionString: String {
        return "\(Info.version) (\(Info.sentryVersion))"
    }
    
    internal static let queueName = "io.sentry.event.queue"
    
    // MARK: - Enums
    
    internal struct Info {
        static let version: String = "1.3.0"
        static let sentryVersion: Int = 7
    }
    
    // MARK: - Attributes
    
    internal let dsn: DSN
    internal(set) var crashHandler: CrashHandler? {
        didSet {
            crashHandler?.startCrashReporting()
            crashHandler?.releaseVersion = releaseVersion
            crashHandler?.tags = tags
            crashHandler?.extra = extra
            crashHandler?.user = user
        }
    }
    
    public lazy var breadcrumbs: BreadcrumbStore = {
        let store = BreadcrumbStore()
        store.storeUpdated = {
            self.crashHandler?.breadcrumbsSerialized = $0.serialized
        }
        return store
    }()
    
    internal var stacktraceSnapshot: Event.StacktraceSnapshot?
    
    #if os(iOS)
    public typealias UserFeedbackViewContollers = (navigationController: UINavigationController, userFeedbackTableViewController: UserFeedbackTableViewController)
    
    private var userFeedbackViewControllers: UserFeedbackViewContollers?
    
    public var delegate: SentryClientUserFeedbackDelegate?
    private(set) var userFeedbackViewModel: UserFeedbackViewModel?
    private(set) var lastSuccessfullySentEvent: Event? {
        didSet {
            guard nil != lastSuccessfullySentEvent else {
                return
            }
            #if swift(>=3.0)
                DispatchQueue.main.async {
                    self.delegate?.userFeedbackReady()
                }
            #else
                dispatch_async(dispatch_get_main_queue(), {
                self.delegate?.userFeedbackReady()
                })
            #endif
        }
    }
    #endif
    
    // MARK: EventProperties
    
    public var releaseVersion: String? {
        didSet { crashHandler?.releaseVersion = releaseVersion }
    }
    public var tags: EventTags = [:] {
        didSet { crashHandler?.tags = tags }
    }
    public var extra: EventExtra = [:] {
        didSet { crashHandler?.extra = extra }
    }
    public var user: User? = nil {
        didSet { crashHandler?.user = user }
    }
    
    public typealias EventBeforeSend = (inout Event) -> ()
    /// Use this block to get the event that will be send with the next
    public var beforeSendEventBlock: EventBeforeSend?
    
    /// Creates a Sentry object to use for reporting
    internal init(dsn: DSN) {
        self.dsn = dsn
        
        #if swift(>=3.0)
            self.releaseVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        #else
            self.releaseVersion = NSBundle.mainBundle().infoDictionary?["CFBundleShortVersionString"] as? String
        #endif
        
        super.init()
        
        do{
            try moveOldDirectory()
        } catch {}
        
        sendEventsOnDiskInBackground()
    }
    
    /// Creates a Sentry object iff a valid DSN is provided
    @objc public convenience init?(dsnString: String) {
        // Silently not creating a client if dsnString is empty string
        if dsnString.isEmpty {
            SentryLog.Debug.log("DSN provided was empty - not creating a SentryClient object")
            return nil
        }
        
        // Try to create a client with a DSN string
        // Log error if cannot make one
        do {
            let dsn = try DSN(dsnString)
            self.init(dsn: dsn)
        } catch SentryError.InvalidDSN {
            SentryLog.Error.log("DSN is invalid")
            return nil
        } catch {
            SentryLog.Error.log("DSN is invalid")
            return nil
        }
    }
    
    /*
     Captures current stracktrace of the thread and stores it in internal var stacktraceSnapshot
     Use event.fetchStacktrace() to fill your event with this stacktrace
     */
    @objc public func snapshotStacktrace() {
        guard let crashHandler = crashHandler else {
            SentryLog.Error.log("crashHandler not yet initialized")
            return
        }
        KSCrash.sharedInstance().reportUserException("", reason: "", language: "", lineOfCode: "", stackTrace: [""], terminateProgram: false)
        crashHandler.sendAllReports()
    }
    
    /*
     Reports message to Sentry with the given level
     - Parameter message: The message to send to Sentry
     - Parameter level: The severity of the message
     */
    @objc public func captureMessage(_ message: String, level: SentrySeverity = .Info) {
        self.captureEvent(Event(message, level: level))
    }
    
    /// Reports given event to Sentry
    @objc public func captureEvent(_ event: Event) {
        #if swift(>=3.0)
            DispatchQueue(label: SentryClient.queueName).sync {
                self.captureEvent(event, useClientProperties: true)
            }
        #else
            dispatch_sync(dispatch_queue_create(SentryClient.queueName, nil), {
                self.captureEvent(event, useClientProperties: true)
            })
        #endif
    }
    
    #if os(iOS)
    @objc public func enableAutomaticBreadcrumbTracking() {
        SentrySwizzle.enableAutomaticBreadcrumbTracking()
    }
    #endif
    
    /// This will make you app crash, use only for test purposes
    @objc public func crash() {
        fatalError("TEST - Sentry Client Crash")
    }
    
    #if os(iOS)
    /// This will return the UserFeedbackControllers
    public func userFeedbackControllers() -> UserFeedbackViewContollers? {
        guard userFeedbackViewControllers == nil else {
            return userFeedbackViewControllers
        }
        
        var bundle: Bundle? = nil
        #if swift(>=3.0)
            let frameworkBundle = Bundle(for: type(of: self))
            bundle = frameworkBundle
            if let bundleURL = frameworkBundle.url(forResource: "storyboards", withExtension: "bundle") {
                bundle = Bundle(url: bundleURL)
            }
        #else
            let frameworkBundle = NSBundle(forClass: self.dynamicType)
            bundle = frameworkBundle
            if let bundleURL = frameworkBundle.URLForResource("storyboards", withExtension: "bundle") {
                bundle = NSBundle(URL: bundleURL)
            }
        #endif
        
        let storyboard = UIStoryboard(name: "UserFeedback", bundle: bundle)
        if let navigationViewController = storyboard.instantiateInitialViewController() as? UINavigationController,
            let userFeedbackViewController = navigationViewController.viewControllers.first as? UserFeedbackTableViewController,
            let viewModel = userFeedbackViewModel {
            userFeedbackViewController.viewModel = viewModel
            userFeedbackViewControllers = (navigationViewController, userFeedbackViewController)
            return userFeedbackViewControllers
        }
        return nil
    }
    
    @objc public func userFeedbackTableViewController() -> UserFeedbackTableViewController? {
        return userFeedbackControllers()?.userFeedbackTableViewController
    }
    
    @objc public func userFeedbackNavigationViewController() -> UINavigationController? {
        return userFeedbackControllers()?.navigationController
    }
    
    /// Call this with your custom UserFeedbackViewModel to configure the UserFeedbackViewController
    @objc public func enableUserFeedbackAfterFatalEvent(userFeedbackViewModel: UserFeedbackViewModel = UserFeedbackViewModel()) {
        self.userFeedbackViewModel = userFeedbackViewModel
    }
    
    internal func sentUserFeedback() {
        #if swift(>=3.0)
            DispatchQueue.main.async {
                self.delegate?.userFeedbackSent()
            }
        #else
            dispatch_async(dispatch_get_main_queue(), {
                self.delegate?.userFeedbackSent()
            })
        #endif
        lastSuccessfullySentEvent = nil
    }
    
    #endif
    
    /*
     Reports given event to Sentry
     - Parameter event: An event struct
     - Parameter useClientProperties: Should the client's user, tags and extras also be reported (default is `true`)
     */
    internal func captureEvent(_ event: Event, useClientProperties: Bool = true, completed: SentryEndpointRequestFinished? = nil) {
        // Don't allow client attributes to be used when reporting an `Exception`
        if useClientProperties {
            event.user = event.user ?? user
            event.releaseVersion = event.releaseVersion ?? releaseVersion
            
            if JSONSerialization.isValidJSONObject(tags) {
                event.tags.unionInPlace(tags)
            }
            
            if JSONSerialization.isValidJSONObject(extra) {
                event.extra.unionInPlace(extra)
            }
        }
        
        if nil == event.breadcrumbsSerialized { // we only want to set the breadcrumbs if there are non in the event
            event.breadcrumbsSerialized = breadcrumbs.serialized
        }
        breadcrumbs.clear()
        
        sendEvent(event) { [weak self] success in
            completed?(success)
            guard !success else {
                #if os(iOS)
                    if event.level == .Fatal {
                        self?.lastSuccessfullySentEvent = event
                    }
                #endif
                return
            }
            self?.saveEvent(event)
        }
        
        // In the end we check if there are any events still stored on disk and send them
        sendEventsOnDiskInBackground()
    }
    
    /// Sends events that are stored on disk to the server
    private func sendEventsOnDiskInBackground() {
        #if swift(>=3.0)
            DispatchQueue(label: SentryClient.queueName).sync {
                self.sendEventsOnDisk()
            }
        #else
            dispatch_sync(dispatch_queue_create(SentryClient.queueName, nil), {
                self.sendEventsOnDisk()
            })
        #endif
    }
    
    /// Attempts to send all events that are saved on disk
    private func sendEventsOnDisk() {
        let events = savedEvents()
        
        for savedEvent in events {
            sendEvent(savedEvent) { success in
                guard success else { return }
                savedEvent.deleteEvent()
            }
        }
    }
}
