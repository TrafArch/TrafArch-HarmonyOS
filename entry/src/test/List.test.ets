import nfcScanSessionTest from './NfcScanSession.test';
import transitReadTest from './TransitRead.test';

export default function testsuite() {
  nfcScanSessionTest();
  transitReadTest();
}
