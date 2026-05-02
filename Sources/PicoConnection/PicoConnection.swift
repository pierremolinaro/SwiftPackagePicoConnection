//--------------------------------------------------------------------------------------------------
//  Created by Pierre Molinaro on 17/10/2025.
//--------------------------------------------------------------------------------------------------

import Foundation
import Network

//--------------------------------------------------------------------------------------------------

@Observable @MainActor public final class PicoConnection <SEND_CODE : WiFiSendCodeProtocol, RECEIVE_CODE : WiFiReceiveCodeProtocol> : NSObject, NetServiceBrowserDelegate, NetServiceDelegate {

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private(set) public var mConnectionState = ConnectionState.disconnected
  private(set) public var isConnected = false
  private(set) public var mConnectionLost = false
  public let mServiceTypeName : String
  public let mServiceName : String

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  @ObservationIgnored private let mTrace : Bool
  @ObservationIgnored private let mQueue = DispatchQueue (label: "network.connection")
  @ObservationIgnored private var mServiceBrowser : NWBrowser? = nil
  @ObservationIgnored private var mConnection : NWConnection? = nil
  @ObservationIgnored private var mSendAliveToPeerTimer : Timer? = nil
  @ObservationIgnored private var mPeerIsAliveTimer : Timer? = nil
  @ObservationIgnored private var mConnectionIsAlive = false
  @ObservationIgnored private var mAliveMessageReceiveDate = DispatchTime.now()

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  public init (serviceTypeName inServiceTypeName : String,
               serviceName inServiceName : String,
               trace inTrace : Bool) {
    self.mServiceTypeName = inServiceTypeName
    self.mServiceName = inServiceName
    self.mTrace = inTrace
    super.init ()
    self.startBrowsing ()
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  deinit {
    self.mServiceBrowser?.browseResultsChangedHandler = nil
    self.mServiceBrowser?.cancel ()
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private(set) public var mSendingPublishedState = false {
    didSet {
      if self.mSendingPublishedState && !oldValue {
        DispatchQueue.main.asyncAfter (deadline: .now () + 0.25) {
          self.mSendingPublishedState = false
        }
      }
    }
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private(set) public var mReceivingPublishedState = false {
    didSet {
      if self.mReceivingPublishedState && !oldValue {
        DispatchQueue.main.asyncAfter (deadline: .now () + 0.25) {
          self.mReceivingPublishedState = false
        }
      }
    }
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private func startBrowsing () {
    self.mServiceBrowser?.browseResultsChangedHandler = nil
    self.mServiceBrowser?.cancel ()
    let parameters = NWParameters ()
    parameters.allowLocalEndpointReuse = true
    parameters.preferNoProxies = true
    parameters.acceptLocalOnly = true
    self.mServiceBrowser = NWBrowser (for: .bonjour (type: self.mServiceTypeName, domain: nil), using: parameters)
    self.mConnectionState = .searching
    if self.mTrace {
      print ("searchForServices \(self.mServiceTypeName)")
    }
    self.mServiceBrowser?.browseResultsChangedHandler = self.browseResultsChanged
    self.mServiceBrowser?.start (queue: self.mQueue)
  }


  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  nonisolated func browseResultsChanged (newResults inNewResults : Set<NWBrowser.Result>,
                                         changes inChanges : Set<NWBrowser.Result.Change>) {
    DispatchQueue.main.async {
      for resultChange in inChanges {
        switch resultChange {
        case .changed (old: let ancienService, new: let nouveauService, flags: let flags) :
          if self.mTrace {
            print("  Changement service: \(ancienService) --> \(nouveauService), flags: \(flags)")
          }
        case .identical :
          if self.mTrace {
            print("  Service: identical")
          }
        case .removed (let removedService) :
          switch removedService.endpoint {
          case let .service (name, type, domain, _):
            if self.mTrace {
              print("  Disparition service: \(name), type: \(type), domaine: \(domain)")
            }
            if name == self.mServiceName, self.mConnection != nil {
              self.disconnect ()
            }
          default:
            break
          }
        case .added (let addedService) :
          switch addedService.endpoint {
          case let .service (name, type, domain, _) :
            if self.mTrace {
              print("  Apparition service : \(name), type: \(type), domaine: \(domain), connexion \(self.mConnection != nil)")
            }
            if name == self.mServiceName, self.mConnection == nil {
              self.openConnection (with: addedService)
            }
          default:
            break
          }
        @unknown default:
          fatalError ()
        }
      }
    }
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private func openConnection (with inResult : NWBrowser.Result) {
    if self.mTrace {
      print ("Open connection…")
    }
    self.mServiceBrowser?.browseResultsChangedHandler = nil
    self.mServiceBrowser?.cancel ()
    self.mServiceBrowser = nil
    self.mConnectionState = .connecting
    let connection = NWConnection (to: inResult.endpoint, using: .tcp)
    self.mConnection = connection
    self.mConnectionLost = false
    connection.stateUpdateHandler = self.connectionStateDidChange
    connection.start (queue: self.mQueue)
    self.startReceive ()
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private func disconnect () {
    if self.mTrace {
      print ("Disconnect")
    }
    self.mConnectionState = .disconnected
    self.isConnected = false
    self.mConnection?.stateUpdateHandler = nil
    self.mConnection?.forceCancel ()
    self.mConnection = nil
    self.mSendAliveToPeerTimer?.invalidate ()
    self.mSendAliveToPeerTimer =  nil
    self.mPeerIsAliveTimer?.invalidate ()
    self.mPeerIsAliveTimer = nil
    self.startBrowsing ()
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  func connectionLost (_ inError : NWError) {
    if self.mTrace {
      print ("connectionLost with error \(inError)")
    }
    self.disconnect ()
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private nonisolated func connectionStateDidChange (_ inState : NWConnection.State) {
    DispatchQueue.main.async {
      switch inState {
      case .setup:
        if self.mTrace {
          print("Connection setup…")
        }
      case .waiting (let error):
        if self.mTrace {
          print("Connection waiting, error \(error)")
        }
        self.connectionLost (error)
      case .preparing:
        if self.mTrace {
          print ("Connection preparing…")
        }
        self.mConnectionState = .preparing
      case .ready :
        if self.mTrace {
          print ("Connection ready --> connected")
        }
        let remoteEndPointString : String
        switch self.mConnection?.currentPath?.remoteEndpoint {
        case .hostPort (host: let host, port: let port) :
          switch host {
          case .ipv4 (let address) :
            remoteEndPointString = "\(address.rawValue [0]).\(address.rawValue [1]).\(address.rawValue [2]).\(address.rawValue [3]):\(port)"
          default:
            remoteEndPointString = "\(host):\(port)!!"
          }
        default:
          remoteEndPointString = "?"
        }
        self.mConnectionState = .connected (remoteEndPointString)
        self.isConnected = true
        self.mSendAliveToPeerTimer = Timer.scheduledTimer (withTimeInterval: 1.0, repeats: true) { _ in
          DispatchQueue.main.async { self.sendAliveMessage () }
        }
        self.mConnectionIsAlive = true
        self.mAliveMessageReceiveDate = DispatchTime.now ()
        self.mPeerIsAliveTimer = Timer.scheduledTimer (withTimeInterval: 3.0, repeats: true) { _ in
          DispatchQueue.main.async {
            if !self.mConnectionIsAlive, (self.mAliveMessageReceiveDate + .seconds(2)) < DispatchTime.now () {
              self.mConnectionLost = true
              self.disconnect ()
            }
            self.mConnectionIsAlive = false
          }
        }
      case .failed (let error) :
        if self.mTrace {
          print ("Connection failed, error \(error)…")
        }
        self.connectionLost (error)
      case .cancelled :
        if self.mTrace {
          print ("Connection cancelled")
        }
        self.disconnect ()
      @unknown default:
        if self.mTrace {
          print("Connection ???")
        }
      }
    }
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private func startReceive () {
    self.mConnection?.receive (minimumIncompleteLength: 1, maximumLength: 65536) { optData, _, isDone, optError in
      DispatchQueue.main.async {
        if let data = optData, !data.isEmpty {
          self.mConnectionIsAlive = true
          self.mAliveMessageReceiveDate = DispatchTime.now ()
          self.appendReceivedData (data)
        }
        if let error = optError {
          print ("did receive, error: \(error)")
          self.disconnect ()
        }else{
          self.startReceive ()
        }
      }
    }
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private func sendAliveMessage () {
    var byte = 0xA1 // Alive Message
    let data = unsafe Data (bytes: &byte, count: 1)
    self.mConnection?.send (content: data, isComplete: true, completion: .contentProcessed { optError in
      DispatchQueue.main.async { self.mSendingPublishedState = true }
      if let error = optError {
        print ("did send, error: \(error)")
        DispatchQueue.main.async { self.connectionLost (error) }
      }
    })
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  public func send (command inCommand : SEND_CODE) {
    var byte = inCommand.rawValue | 0xC0
    let data = unsafe Data (bytes: &byte, count: 1)
    self.mConnection?.send (content: data, isComplete: true, completion: .contentProcessed { optError in
      DispatchQueue.main.async { self.mSendingPublishedState = true }
      if let error = optError {
        print ("did send, error: \(error)")
        DispatchQueue.main.async { self.connectionLost (error) }
      }
    })
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  public func send (encodedU64 inValue : UInt64) {
    var data = Data ()
    data.append (UInt8 ((inValue & 0x0F) | 0x80))
    var v = inValue >> 4
    while v > 0 {
      data.append (UInt8 (v & 0x7F))
      v >>= 7
    }
    self.mConnection?.send (content: data, isComplete: false, completion: .contentProcessed { optError in
      DispatchQueue.main.async { self.mSendingPublishedState = true }
      if let error = optError {
        print ("did send, error: \(error)")
        DispatchQueue.main.async { self.connectionLost (error) }
      }
    })
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  public func send (encodedString inValue : String) {
    var data = Data ()
    data.append (0xA0)
    for utf32 in inValue.unicodeScalars {
      let pointCode : UInt32 = utf32.value
      if (pointCode >= 0x10) && (pointCode <= 0x1F) { // control 0001 xxxx
        data.append (UInt8 (pointCode))
        data.append (0x41) ;
      }else if pointCode <= 0x7F { // ASCII
        data.append (UInt8 (pointCode))
      }else if pointCode <= 0x3FF {
        data.append (UInt8 (pointCode & 0x0F) | 0x10)
        data.append (UInt8 (pointCode >> 4) | 0x40)
      }else if pointCode <= 0xFFFF {
        data.append (UInt8 (pointCode & 0x0F) | 0x10)
        data.append (UInt8 (pointCode >> 4) & 0x3F)
        data.append (UInt8 (pointCode >> 10) | 0x40)
      }else{
        data.append (UInt8 (pointCode & 0x0F) | 0x10)
        data.append (UInt8 (pointCode >> 4) & 0x3F)
        data.append (UInt8 (pointCode >> 10) & 0x3F)
        data.append (UInt8 (pointCode >> 16) | 0x40)
      }
    }
    self.mConnection?.send (content: data, isComplete: false, completion: .contentProcessed { optError in
      DispatchQueue.main.async { self.mSendingPublishedState = true }
      if let error = optError {
        print ("did send, error: \(error)")
        DispatchQueue.main.async { self.connectionLost (error) }
      }
    })
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  public enum ConnectionState : Equatable {
    case disconnected
    case searching
    case connecting
    case preparing
    case connected (String)
    case connectionLost (NWError)
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
  //MARK: RECEPTION
  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  @ObservationIgnored private var mReceivedRawData = Data ()
  @ObservationIgnored var rawByteCount : Int { self.mReceivedRawData.count }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  @ObservationIgnored private var mDecoderState = DecoderState.idle
  @ObservationIgnored private var mDecodingU64Value : UInt64 = 0
  @ObservationIgnored private var mDecodingU64Shift : UInt64 = 0
  @ObservationIgnored private var mDecodingString = Data ()
  @ObservationIgnored private var mParameterStack = [Parameter] ()
  @ObservationIgnored private var mCompletionCallBack : Optional < @MainActor (_ inCommand : Command) -> Void > = nil

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  enum ByteFormat {
    case parameterExtension
    case beginUnsigned
    case beginSigned
    case beginString
    case command
    case undefined
  } ;

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private static func formatForByte (_ inByte : UInt8) -> ByteFormat {
    var result = ByteFormat.undefined
    if (inByte & 0x80) == 0 {
      result = .parameterExtension
    }else if (inByte & 0xF0) == 0x80 {
      result = .beginUnsigned
    }else if (inByte & 0xF0) == 0x90 {
      result = .beginSigned
    }else if inByte == 0xA0 {
      result = .beginString
    }else if (inByte & 0xC0) == 0xC0 {
      result = .command
    }
    return result
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  enum DecoderState {
    case idle
    case decodingUnsigned
    case decodingSigned
    case decodingString
    case error
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  public enum Parameter {
    case u64 (UInt64)
    case s64 (Int64)
    case str (String)

    public var u64 : UInt64? {
      switch self {
      case .u64 (let v): return v
      case .s64, .str: return nil
      }
    }

    public var s64 : Int64? {
      switch self {
      case .s64 (let v): return v
      case .u64, .str: return nil
      }
    }

    public var str : String? {
      switch self {
      case .str (let v): return v
      case .u64, .s64: return nil
      }
    }
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  @MainActor public struct Command {
    public let code : RECEIVE_CODE
    public let parameters : [Parameter]
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private func decodeStringFromByteArray () -> String {
    var utf32Array = [UnicodeScalar] ()
    var multiByteShift : UInt32 = 0
    var utf32Value : UInt32 = 0
    for byte in self.mDecodingString {
      if multiByteShift > 0 {
        if (byte & 0x40) == 0 {
          utf32Value |= UInt32 (byte & 0x3F) << multiByteShift
          multiByteShift += 6
        }else{ // End of multi byte
          utf32Value |= UInt32 (byte & 0x3F) << multiByteShift
          utf32Array.append (UnicodeScalar (utf32Value)!)
          utf32Value = 0 ;
          multiByteShift = 0 ;
        }
      }else if byte >= 0x10, byte <= 0x1F { // Start multibyte
        utf32Value = UInt32 (byte & 0x0F)
        multiByteShift = 4
      }else{
        utf32Array.append (UnicodeScalar (byte))
      }
    }
    return String (String.UnicodeScalarView (utf32Array))
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private func closeCurrentValueDecoding () {
    switch self.mDecoderState {
    case .decodingUnsigned :
      self.mParameterStack.append (.u64 (self.mDecodingU64Value))
      self.mDecoderState = .idle
    case .decodingSigned :
      let v = Int64 (bitPattern: ~self.mDecodingU64Value) ;
      self.mParameterStack.append (.s64 (v))
      self.mDecoderState = .idle
    case .decodingString :
      let s = self.decodeStringFromByteArray () ;
      self.mParameterStack.append (.str (s))
      self.mDecoderState = .idle
    case .idle :
      ()
    case .error :
      ()
    }
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  public func setCompletionCallBack (_ inCompletionCallBack : Optional < @MainActor  (_ inCommand : Command) -> Void >) {
    self.mReceivedRawData.removeAll (keepingCapacity: true)
    self.mDecoderState = .idle
    self.mCompletionCallBack = inCompletionCallBack
  }
  
  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private func appendReceivedData (_ inData : Data) {
    self.mReceivingPublishedState = true
    self.mReceivedRawData += inData
    for byte in inData {
      let f : ByteFormat = Self.formatForByte (byte)
      switch f {
      case .parameterExtension :
        switch self.mDecoderState {
        case .decodingUnsigned :
          self.mDecodingU64Value |= UInt64 (byte & 0x7F) << self.mDecodingU64Shift
          self.mDecodingU64Shift += 7
        case .decodingSigned :
          self.mDecodingU64Value |= UInt64 (byte & 0x7F) << self.mDecodingU64Shift
          self.mDecodingU64Shift += 7
        case .decodingString :
          self.mDecodingString.append (byte)
        case .idle :
          ()
        case .error :
          ()
        }
      case .beginUnsigned :
        self.closeCurrentValueDecoding ()
        self.mDecodingU64Value = UInt64 (byte & 0x0F)
        self.mDecodingU64Shift = 4
        self.mDecoderState = .decodingUnsigned
      case .beginSigned :
        self.closeCurrentValueDecoding () ;
        self.mDecodingU64Value = UInt64 (byte & 0x0F)
        self.mDecodingU64Shift = 4
        self.mDecoderState = .decodingSigned
      case .beginString :
        self.closeCurrentValueDecoding ()
        self.mDecodingString.removeAll ()
        self.mDecoderState = .decodingString
      case .command :
        self.closeCurrentValueDecoding ()
        if let receiveCode = RECEIVE_CODE (rawValue: byte & 0x3F) {
          let command = Command (code: receiveCode, parameters: self.mParameterStack)
          DispatchQueue.main.async {
            self.mCompletionCallBack? (command)
          }
        }
        self.mParameterStack.removeAll ()
      case .undefined :
        ()
      }
    }
  }

  // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

}

//--------------------------------------------------------------------------------------------------
