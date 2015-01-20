/*
 *  GeometryManager.mm
 *  WhirlyGlobeLib
 *
 *  Created by Steve Gifford on 11/25/15.
 *  Copyright 2012-2014 mousebird consulting
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

#import "GeometryManager.h"
#import "SelectionManager.h"
#import "NSDictionary+Stuff.h"
#import "UIColor+Stuff.h"

using namespace Eigen;
using namespace WhirlyKit;

typedef enum {GeometryBBoxSingle,GeometryBBoxTriangle,GeometryBBoxNone} GeometryBoundingBox;

// Used to pass geometry around internally
@interface GeomInfo : NSObject
@property (nonatomic) UIColor *color;
@property (nonatomic,assign) float fade;
@property (nonatomic,assign) float minVis,maxVis;
@property (nonatomic,assign) int drawPriority;
@property (nonatomic,assign) bool enable;
@property (nonatomic,assign) int boundingBox;

- (id)initWithDesc:(NSDictionary *)desc;
@end

@implementation GeomInfo

- (id)initWithDesc:(NSDictionary *)desc
{
    self = [super init];
    if (!self)
        return nil;
    
    [self parseDict:desc];
    
    return self;
}

- (void)parseDict:(NSDictionary *)dict
{
    _enable = [dict boolForKey:@"enable" default:YES];
    _minVis = [dict floatForKey:@"minVis" default:DrawVisibleInvalid];
    _maxVis = [dict floatForKey:@"maxVis" default:DrawVisibleInvalid];
    _color = [dict objectForKey:@"color" checkType:[UIColor class] default:[UIColor whiteColor]];
    _fade = [dict floatForKey:@"fade" default:0.0];
    _drawPriority = [dict intForKey:@"drawPriority" default:0];
    _boundingBox = [dict enumForKey:@"boundingbox" values:@[@"single",@"triangle",@"none"] default:GeometryBBoxSingle];
}

@end

namespace WhirlyKit
{

void GeomSceneRep::clearContents(SelectionManager *selectManager,ChangeSet &changes)
{
    for (SimpleIDSet::iterator it = drawIDs.begin();
         it != drawIDs.end(); ++it)
        changes.push_back(new RemDrawableReq(*it));
    if (selectManager && !selectIDs.empty())
        selectManager->removeSelectables(selectIDs);
}

void GeomSceneRep::enableContents(SelectionManager *selectManager,bool enable,ChangeSet &changes)
{
    for (SimpleIDSet::iterator it = drawIDs.begin();
         it != drawIDs.end(); ++it)
        changes.push_back(new OnOffChangeRequest(*it, enable));
    if (selectManager && !selectIDs.empty())
        selectManager->enableSelectables(selectIDs, enable);
}
    
GeometryRaw::GeometryRaw()
    : type(WhirlyKitGeometryTriangles), texId(EmptyIdentity)
{
}

GeometryRaw::GeometryRaw(const GeometryRaw &that)
{
    type = that.type;
    pts = that.pts;
    norms = that.norms;
    texCoords = that.texCoords;
    colors = that.colors;
    triangles = that.triangles;
    texId = that.texId;
}
    
bool GeometryRaw::operator == (const GeometryRaw &that) const
{
    return texId == that.texId && type == that.type;
}

bool GeometryRaw::isValid() const
{
    if (type != WhirlyKitGeometryLines && type != WhirlyKitGeometryTriangles)
        return false;
    int numPoints = (int)pts.size();
    if (numPoints == 0)
        return false;
    
    if (!norms.empty() && norms.size() != numPoints)
        return false;
    if (!texCoords.empty() && texCoords.size() != numPoints)
        return false;
    if (!colors.empty() && colors.size() != numPoints)
        return false;
    if (type == WhirlyKitGeometryTriangles && triangles.empty())
        return false;
    if (texId != EmptyIdentity && texCoords.empty())
        return false;
    for (unsigned int ii=0;ii<triangles.size();ii++)
    {
        RawTriangle tri = triangles[ii];
        for (unsigned int jj=0;jj<3;jj++)
            if (tri.verts[jj] >= pts.size() || tri.verts[jj] < 0)
                return false;
    }
    
    return true;
}

void GeometryRaw::applyTransform(const Matrix4d &mat)
{
    for (unsigned int ii=0;ii<pts.size();ii++)
    {
        Point3d &pt = pts[ii];
        Vector4d outPt = mat * Eigen::Vector4d(pt.x(),pt.y(),pt.z(),1.0);
        pt = Point3d(outPt.x()/outPt.w(),outPt.y()/outPt.w(),outPt.z()/outPt.w());
    }
    
    for (unsigned int ii=0;ii<norms.size();ii++)
    {
        Point3d &norm = norms[ii];
        Vector4d projNorm = mat * Eigen::Vector4d(norm.x(),norm.y(),norm.z(),0.0);
        norm = Point3d(projNorm.x(),projNorm.y(),projNorm.z()).normalized();
    }
}
    
void GeometryRaw::estimateSize(int &numPts,int &numTris)
{
    numPts = pts.size();
    numTris = triangles.size();
}

void GeometryRaw::buildDrawable(BasicDrawable *draw,const Eigen::Matrix4d &mat)
{
    if (!isValid())
        return;
    
    switch (type)
    {
        case WhirlyKitGeometryLines:
            draw->setType(GL_LINES);
            break;
        case WhirlyKitGeometryTriangles:
            draw->setType(GL_TRIANGLES);
            break;
        default:
            break;
    }
    draw->setTexId(0,texId);
    unsigned int baseVert = draw->getNumPoints();
    for (unsigned int ii=0;ii<pts.size();ii++)
    {
        const Point3d &pt = pts[ii];
        Vector4d outPt = mat * Eigen::Vector4d(pt.x(),pt.y(),pt.z(),1.0);
        Point3d newPt(outPt.x()/outPt.w(),outPt.y()/outPt.w(),outPt.z()/outPt.w());
        draw->addPoint(newPt);
        if (!norms.empty())
        {
            const Point3d &norm = norms[ii];
            // Note: Not the right way to transform normals
            Vector4d projNorm = mat * Eigen::Vector4d(norm.x(),norm.y(),norm.z(),0.0);
            Point3d newNorm(projNorm.x(),projNorm.y(),projNorm.z());
            newNorm.normalize();
            draw->addNormal(newNorm);
        }
        if (texId != EmptyIdentity)
            draw->addTexCoord(0,texCoords[ii]);
        if (!colors.empty())
        {
            draw->addColor(colors[ii]);
        }
    }
    for (unsigned int ii=0;ii<triangles.size();ii++)
    {
        RawTriangle tri = triangles[ii];
        draw->addTriangle(BasicDrawable::Triangle(tri.verts[0]+baseVert,tri.verts[1]+baseVert,tri.verts[2]+baseVert));
    }
}
    
GeometryManager::GeometryManager()
{
    pthread_mutex_init(&geomLock, NULL);
}
    
GeometryManager::~GeometryManager()
{
    pthread_mutex_destroy(&geomLock);
    for (GeomSceneRepSet::iterator it = sceneReps.begin();
         it != sceneReps.end(); ++it)
        delete *it;
    sceneReps.clear();
}
    


SimpleIdentity GeometryManager::addGeometry(std::vector<GeometryRaw> &geom,const std::vector<Eigen::Matrix4d> &instances,NSDictionary *desc,ChangeSet &changes)
{
    SelectionManager *selectManager = (SelectionManager *)scene->getManager(kWKSelectionManager);
    GeomSceneRep *sceneRep = new GeomSceneRep();
    
    GeomInfo *geomInfo = [[GeomInfo alloc] initWithDesc:desc];

    // Sort the geometry by type and texture
    std::vector<std::vector<GeometryRaw *>> sortedGeom;
    for (unsigned int ii=0;ii<geom.size();ii++)
    {
        GeometryRaw *raw = &geom[ii];
        bool found = false;
        for (unsigned int jj=0;jj<sortedGeom.size();jj++)
        {
            std::vector<GeometryRaw *> &sg = sortedGeom[jj];
            if (*(sg.at(0)) == *raw)
            {
                found = true;
                sg.push_back(raw);
                break;
            }
        }
        if (!found)
        {
            std::vector<GeometryRaw *> arr;
            arr.push_back(raw);
            sortedGeom.push_back(arr);
        }
    }
    
    // Work through the model instances
    for (unsigned int ii=0;ii<instances.size();ii++)
    {
        Matrix4d inInstMat = instances[ii];
        Vector4d center = inInstMat * Vector4d(0,0,0,1);
        center.x() /= center.w();  center.y() /= center.w();  center.z() /= center.w();
        Eigen::Affine3d transBack(Eigen::Translation3d(-center.x(),-center.y(),-center.z()));
        Matrix4d transBackMat = transBack.matrix();
        Matrix4d instMat = transBackMat * inInstMat;
        
        // Convert the sorted lists of geometry into drawables
        for (unsigned int jj=0;jj<sortedGeom.size();jj++)
        {
            BasicDrawable *draw = NULL;
            std::vector<GeometryRaw *> &sg = sortedGeom[jj];
            for (unsigned int kk=0;kk<sg.size();kk++)
            {
                GeometryRaw *raw = sg[kk];
                int numPts,numTris;
                raw->estimateSize(numPts, numTris);
                if (!draw || (draw->getNumPoints() + numPts > MaxDrawablePoints) ||
                    (draw->getNumTris() + numTris > MaxDrawableTriangles))
                {
                    draw = new BasicDrawable("Geometry Manager");
                    draw->setType((raw->type == WhirlyKitGeometryLines ? GL_LINES : GL_TRIANGLES));
                    draw->setOnOff(geomInfo.enable);
                    draw->setColor([geomInfo.color asRGBAColor]);
                    draw->setVisibleRange(geomInfo.minVis, geomInfo.maxVis);
                    draw->setDrawPriority(geomInfo.drawPriority);
                    draw->setRequestZBuffer(true);
                    draw->setWriteZBuffer(true);
                    Eigen::Affine3d trans(Eigen::Translation3d(center.x(),center.y(),center.z()));
                    Matrix4d transMat = trans.matrix();
                    draw->setMatrix(&transMat);
                    sceneRep->drawIDs.insert(draw->getId());
                    changes.push_back(new AddDrawableReq(draw));
                }
                
                raw->buildDrawable(draw,instMat);
                // Note: Selection
            }
        }
        
        // Note: Not sharing drawables between instances
    }
    
    SimpleIdentity geomID = sceneRep->getId();
    
    pthread_mutex_lock(&geomLock);
    sceneReps.insert(sceneRep);
    pthread_mutex_unlock(&geomLock);
    
    return geomID;
}

void GeometryManager::enableGeometry(SimpleIDSet &geomIDs,bool enable,ChangeSet &changes)
{
    SelectionManager *selectManager = (SelectionManager *)scene->getManager(kWKSelectionManager);
    
    pthread_mutex_lock(&geomLock);
    
    for (SimpleIDSet::iterator git = geomIDs.begin(); git != geomIDs.end(); ++git)
    {
        GeomSceneRep dummyRep(*git);
        GeomSceneRepSet::iterator it = sceneReps.find(&dummyRep);
        if (it != sceneReps.end())
        {
            GeomSceneRep *geomRep = *it;
            geomRep->enableContents(selectManager,enable,changes);
        }
    }
    
    pthread_mutex_unlock(&geomLock);
}

void GeometryManager::removeGeometry(SimpleIDSet &geomIDs,ChangeSet &changes)
{
    SelectionManager *selectManager = (SelectionManager *)scene->getManager(kWKSelectionManager);

    pthread_mutex_lock(&geomLock);
    
    NSTimeInterval curTime = CFAbsoluteTimeGetCurrent();
    for (SimpleIDSet::iterator git = geomIDs.begin(); git != geomIDs.end(); ++git)
    {
        GeomSceneRep dummyRep(*git);
        GeomSceneRepSet::iterator it = sceneReps.find(&dummyRep);
        
        if (it != sceneReps.end())
        {
            GeomSceneRep *sceneRep = *it;
            
            if (sceneRep->fade > 0.0)
            {
                for (SimpleIDSet::iterator it = sceneRep->drawIDs.begin();
                     it != sceneRep->drawIDs.end(); ++it)
                    changes.push_back(new FadeChangeRequest(*it, curTime, curTime+sceneRep->fade));
                
                // Spawn off the deletion for later
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, sceneRep->fade * NSEC_PER_SEC),
                               scene->getDispatchQueue(),
                               ^{
                                   SimpleIDSet theIDs;
                                   theIDs.insert(sceneRep->getId());
                                   ChangeSet delChanges;
                                   removeGeometry(theIDs, delChanges);
                                   scene->addChangeRequests(delChanges);
                               }
                               );
                
                sceneRep->fade = 0.0;
            } else {
                sceneRep->clearContents(selectManager,changes);
                sceneReps.erase(it);
                delete sceneRep;
            }
        }
    }

    pthread_mutex_unlock(&geomLock);
}

}
