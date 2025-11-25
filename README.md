# Gyoji
Gyoji acts as the referee between SumoLogic's Universal Collector and external cloud APIs.

SumoLogic's out-of-the-box Universal Collector lacks the flexibility required for complex authentication flows (like Azure AD Client Secrets) or specific header formats. Gyoji serves as a lightweight middleware layer that accepts the requests from SumoLogic, injects the necessary authentication context, reshapes the payload, and forwards the valid request to the destination provider.
