import localUnitTest from './LocalUnit.test';
import nfcScanSessionTest from './NfcScanSession.test';
import transitReadTest from './TransitRead.test';

export default function testsuite() {
  localUnitTest();
  nfcScanSessionTest();
  transitReadTest();
}
