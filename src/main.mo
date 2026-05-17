import Text "mo:core/Text";

actor Compression {

  /// Returns a greeting message.
  public query func greet(name : Text) : async Text {
    "Hello, " # name # "! Welcome to motoko-compression."
  };

};
