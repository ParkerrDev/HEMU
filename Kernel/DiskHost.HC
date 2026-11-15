import U0 DskFail(U8 *msg);
import U0 DskImageRead(I64 off,I64 size,U8 *dst);
import U0 DskSectorRead(I64 lba,I64 count,U8 *dst);
import U0 DskSectorWrite(I64 lba,I64 count,U8 *src);
import U0 DskEntry(U16 *name,I64 attr,I64 clus,I64 size,I64 off);
import U0 DskResult(U8 *buf,I64 size);
import Bool DskNameEq(U16 *a,U16 *b);
#include "Disk"
